# SyncTray

A native macOS menu bar app for monitoring rclone sync operations with real-time notifications.

![macOS 13.0+](https://img.shields.io/badge/macOS-13.0+-blue)
![Swift 5](https://img.shields.io/badge/Swift-5-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **Menu Bar Status**: Live sync status icon (idle/syncing/error/drive not mounted)
- **Notifications**: Smart batched notifications for file changes
  - 1-3 files: Lists individual file names
  - 4+ files: Shows summary count
  - Click notification to open the sync directory
- **Recent Changes List**: View last 20 synced files with clickable items to reveal in Finder
- **Manual Sync Trigger**: Start a sync directly from the menu bar
- **Drive Mount Detection**: Automatic status update when external drives mount/unmount
- **Launch at Login**: Built-in option to start with macOS
- **Fully Configurable**: Set your own log file, sync script, and directory paths

## Screenshots

*Coming soon*

## Requirements

- macOS 13.0 or later
- [rclone](https://rclone.org/) installed and configured
- A sync script that writes to a log file

## Installation

### Option 1: Download Release
Download the latest `.app` from [Releases](../../releases) and drag to `/Applications`.

### Option 2: Build from Source
```bash
git clone https://github.com/yourusername/SyncTray.git
cd SyncTray
xcodebuild -project SyncTray.xcodeproj -scheme SyncTray -configuration Release build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/SyncTray-*/Build/Products/Release/`.

## Setup

### 1. Configure rclone for JSON Logging

Add `--use-json-log` to your rclone command for structured log parsing:

```bash
rclone bisync source:path /local/path \
    --verbose \
    --use-json-log \
    2>&1 | tee -a ~/.local/log/rclone-sync.log
```

### 2. Create a Sync Script

Example sync script (`~/.local/bin/rclone-sync.sh`):

```bash
#!/bin/bash
LOG_FILE="$HOME/.local/log/rclone-sync.log"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting bisync" >> "$LOG_FILE"

rclone bisync remote:path /local/path \
    --verbose \
    --use-json-log \
    --check-access \
    2>&1 | tee -a "$LOG_FILE"

EXIT_CODE=${PIPESTATUS[0]}

if [[ $EXIT_CODE -eq 0 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Bisync completed successfully" >> "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Bisync failed with exit code $EXIT_CODE" >> "$LOG_FILE"
fi
```

Make it executable:
```bash
chmod +x ~/.local/bin/rclone-sync.sh
```

### 3. Configure SyncTray

1. Launch SyncTray
2. Click the menu bar icon and select **Settings...**
3. Configure the paths:
   - **Log File Path**: Where your sync script writes logs
   - **Sync Script Path**: Path to your sync script (for "Sync Now" button)
   - **Sync Directory**: Local folder being synced (for "Open Directory" feature)
   - **Drive Path to Monitor**: External drive path (optional, for mount detection)

### 4. Schedule Automatic Syncs (Optional)

Create a launchd plist (`~/Library/LaunchAgents/com.user.rclone-sync.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.rclone-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/yourusername/.local/bin/rclone-sync.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

Load it:
```bash
launchctl load ~/Library/LaunchAgents/com.user.rclone-sync.plist
```

## Log Format

SyncTray parses both JSON logs (from `--use-json-log`) and plain text markers:

### JSON Log (rclone)
```json
{"time":"2026-02-14T10:30:01Z","level":"info","msg":"Copied (new)","object":"Documents/file.txt"}
```

### Plain Text Markers (your script)
```
2026-02-14 10:30:00 - Starting bisync
2026-02-14 10:31:00 - Bisync completed successfully
2026-02-14 10:31:00 - Bisync failed with exit code 1
```

## Menu Bar Icons

| Icon | State |
|------|-------|
| Gray sync arrows | Idle |
| Blue sync arrows | Syncing |
| Red warning triangle | Error |
| Orange drive with X | Drive not mounted |
| Yellow gear | Setup required |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [rclone](https://rclone.org/) - The powerful sync tool this app monitors
- Apple's SwiftUI and MenuBarExtra APIs
