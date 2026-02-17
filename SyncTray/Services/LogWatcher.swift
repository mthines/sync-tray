import Foundation

protocol LogWatcherDelegate: AnyObject {
    func logWatcher(_ watcher: LogWatcher, didReceiveNewLines lines: [String])
}

final class LogWatcher {
    private var logPath: String
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastReadPosition: UInt64 = 0

    // Polling fallback for reliability
    private var pollTimer: DispatchSourceTimer?
    private var isActivelySyncing: Bool = false
    private let pollQueue = DispatchQueue(label: "com.synctray.logwatcher.poll", qos: .utility)
    private static let heartbeatInterval: TimeInterval = 5.0
    private static let activePollingInterval: TimeInterval = 2.5

    weak var delegate: LogWatcherDelegate?

    init(logPath: String) {
        self.logPath = logPath
    }

    func updateLogPath(_ path: String) {
        stopWatching()
        self.logPath = path
        startWatching()
    }

    func startWatching() {
        stopWatching()

        // Create log file and directory if they don't exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logPath) {
            let directory = (logPath as NSString).deletingLastPathComponent
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            fileManager.createFile(atPath: logPath, contents: nil)
        }

        guard let handle = FileHandle(forReadingAtPath: logPath) else {
            print("Failed to open log file: \(logPath)")
            return
        }

        fileHandle = handle

        // Seek to end to only watch new content
        handle.seekToEndOfFile()
        lastReadPosition = handle.offsetInFile

        let fd = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.handleFileChange()
        }

        source.setCancelHandler { [weak self] in
            self?.fileHandle?.closeFile()
            self?.fileHandle = nil
        }

        self.source = source
        source.resume()

        // Start polling fallback timer
        startPollTimer()

        // Read recent content for context (last 50 lines)
        readRecentLines(count: 50)
    }

    func stopWatching() {
        pollTimer?.cancel()
        pollTimer = nil
        source?.cancel()
        source = nil
        fileHandle?.closeFile()
        fileHandle = nil
    }

    /// Adjust polling frequency based on sync activity
    func setActivelySyncing(_ active: Bool) {
        guard isActivelySyncing != active else { return }
        isActivelySyncing = active

        // Restart poll timer with new interval
        if pollTimer != nil {
            startPollTimer()
        }
    }

    // MARK: - Polling Fallback

    private func startPollTimer() {
        pollTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        let interval = isActivelySyncing ? Self.activePollingInterval : Self.heartbeatInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)

        timer.setEventHandler { [weak self] in
            self?.pollForChanges()
        }

        pollTimer = timer
        timer.resume()
    }

    private func pollForChanges() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: logPath)
            let currentSize = attributes[.size] as? UInt64 ?? 0

            if currentSize > lastReadPosition {
                // Missed content - read it
                let missedBytes = currentSize - lastReadPosition
                SyncTraySettings.debugLog("LogWatcher: Polling detected \(missedBytes) missed bytes")
                DispatchQueue.main.async { [weak self] in
                    self?.handleFileChange()
                }
            }
        } catch {
            // File may have been deleted - trigger recovery
            SyncTraySettings.debugLog("LogWatcher: Polling error - \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.stopWatching()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.startWatching()
                }
            }
        }
    }

    private func handleFileChange() {
        guard let handle = fileHandle else { return }

        // Check if file was truncated or rotated
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: logPath)
            let fileSize = attributes[.size] as? UInt64 ?? 0

            if fileSize < lastReadPosition {
                // File was truncated, restart from beginning
                handle.seek(toFileOffset: 0)
                lastReadPosition = 0
            }
        } catch {
            // File might have been deleted, try to reopen
            stopWatching()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startWatching()
            }
            return
        }

        handle.seek(toFileOffset: lastReadPosition)
        let newData = handle.readDataToEndOfFile()
        lastReadPosition = handle.offsetInFile

        guard !newData.isEmpty,
              let content = String(data: newData, encoding: .utf8) else {
            return
        }

        let lines = content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if !lines.isEmpty {
            delegate?.logWatcher(self, didReceiveNewLines: lines)
        }
    }

    private func readRecentLines(count: Int) {
        guard let handle = fileHandle else { return }

        // Only read the last 64KB max to avoid memory issues with large logs
        let maxBytes: UInt64 = 64 * 1024
        let fileSize = handle.seekToEndOfFile()

        if fileSize > maxBytes {
            handle.seek(toFileOffset: fileSize - maxBytes)
        } else {
            handle.seek(toFileOffset: 0)
        }

        let data = handle.readDataToEndOfFile()
        lastReadPosition = handle.offsetInFile

        guard let content = String(data: data, encoding: .utf8) else { return }

        let allLines = content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let recentLines = Array(allLines.suffix(count))
        if !recentLines.isEmpty {
            delegate?.logWatcher(self, didReceiveNewLines: recentLines)
        }
    }

    deinit {
        stopWatching()
    }
}
