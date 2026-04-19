import Foundation

/// Formatters for track metadata display.
public enum Formatters {
    // MARK: - Duration

    /// Formats a playback duration in seconds as `m:ss` or `h:mm:ss`.
    ///
    ///     Formatters.duration(183)   // "3:03"
    ///     Formatters.duration(3723)  // "1:02:03"
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "-:--" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let s = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, s)
        } else {
            return String(format: "%d:%02d", minutes, s)
        }
    }

    // MARK: - Bitrate

    /// Formats a bitrate in kbps.
    ///
    ///     Formatters.bitrate(320) // "320 kbps"
    public static func bitrate(_ kbps: Int?) -> String {
        guard let kbps else { return "" }
        return "\(kbps) kbps"
    }

    // MARK: - File size

    /// Formats a file size in bytes as a human-readable string.
    ///
    ///     Formatters.fileSize(3_145_728) // "3 MB"
    public static func fileSize(_ bytes: Int64) -> String {
        self.bytesFormatter.string(fromByteCount: bytes)
    }

    // MARK: - Rating

    /// Converts a 0–100 integer rating to a 0–5 star count.
    public static func stars(from rating: Int) -> Int {
        Int((Double(rating) / 100.0 * 5).rounded())
    }

    /// Formats an epoch timestamp as a short date string.
    public static func shortDate(epochSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        return Self.shortDateFormatter.string(from: date)
    }

    // MARK: - Private

    /// These formatters are created once and accessed from the main actor only.
    /// `nonisolated(unsafe)` suppresses the strict-concurrency warning for the
    /// static lazy initialiser, which is safe here because all callers are @MainActor.
    private nonisolated(unsafe) static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    private nonisolated(unsafe) static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
