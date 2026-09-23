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

    /// The width a transport time label needs to show `duration(_:)` output
    /// for content up to `longest` seconds, at caption size.
    ///
    ///     Formatters.timeLabelWidth(longest: 331)   // 36, fits "5:31"
    ///     Formatters.timeLabelWidth(longest: 3723)  // 48, fits "1:02:03"
    ///
    /// The labels either side of the scrubber are fixed-width, so the slider
    /// does not shift as the clock ticks. A slot sized for `m:ss` is too narrow
    /// for `h:mm:ss`: at caption size "1:02:03" measures 38.25 pt against the
    /// 36 pt slot, and SwiftUI wraps the last digit onto a second line rather
    /// than overflow it (#563). "10:02:03" measures 44.67 pt, so the wide slot
    /// carries a ten-hour audiobook too.
    ///
    /// Pass the longest value the label will show, not the current position:
    /// sizing on the total keeps the slot still as playback crosses an hour.
    /// Live sources report no duration, so their elapsed time is the longest
    /// value and the slot widens once, an hour in.
    public static func timeLabelWidth(longest seconds: Double) -> Double {
        guard seconds.isFinite, seconds >= 3600 else { return 36 }
        return 48
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

    /// Formats an epoch timestamp as a short date with the time of day, for a
    /// list where the same day appears many times (the play history).
    public static func shortDateTime(epochSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        return Self.shortDateTimeFormatter.string(from: date)
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

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let shortDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
