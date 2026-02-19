import Foundation

/// Centralized formatting utilities for consistent display across the app
enum SyncFormatters {
    /// Format a duration in seconds as a human-readable ETA string
    /// - Parameter seconds: Duration in seconds
    /// - Returns: Formatted string like "45s", "5m30s", or "1h30m"
    static func formatETA(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3600)h\(seconds % 3600 / 60)m"
    }

    /// Format a duration in seconds as a human-readable ETA string with full precision
    /// - Parameter seconds: Duration in seconds
    /// - Returns: Formatted string like "45s", "5m30s", or "1h30m45s" (includes seconds for longer durations)
    static func formatETAWithSeconds(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3600)h\(seconds % 3600 / 60)m\(seconds % 60)s"
    }

    /// Format bytes as a human-readable string using the system formatter
    /// - Parameter bytes: Number of bytes
    /// - Returns: Formatted string like "1.5 GB" or "500 KB"
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Format a transfer speed as a human-readable string
    /// - Parameter bytesPerSecond: Speed in bytes per second
    /// - Returns: Formatted string like "1.5 GB/s" or "500 KB/s"
    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        "\(formatBytes(Int64(bytesPerSecond)))/s"
    }

    /// Format a transfer speed from integer bytes per second
    /// - Parameter bytesPerSecond: Speed in bytes per second
    /// - Returns: Formatted string like "1.5 GB/s" or "500 KB/s"
    static func formatSpeed(_ bytesPerSecond: Int64) -> String {
        "\(formatBytes(bytesPerSecond))/s"
    }
}
