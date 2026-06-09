import Observability
import SwiftUI

// MARK: - LogConsoleRow

/// A single row in the in-app log console.
///
/// Displays timestamp, level badge, category, and message in a fixed-width monospaced
/// layout. The level badge always shows text (never color alone) so users with
/// "Differentiate Without Color" enabled can still distinguish severity.
public struct LogConsoleRow: View {
    let entry: LogEntry

    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    public init(entry: LogEntry) {
        self.entry = entry
    }

    // MARK: - Body

    public var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: Self.format(self.entry.timestamp))
                .frame(width: 88, alignment: .leading)
                .foregroundStyle(Color.textTertiary)

            Text(verbatim: self.entry.level.label)
                .frame(width: 58, alignment: .leading)
                .foregroundStyle(self.differentiateWithoutColor ? Color.textPrimary : self.levelColor)

            Text(verbatim: self.entry.category.rawValue)
                .frame(width: 76, alignment: .leading)
                .foregroundStyle(Color.textSecondary)

            Text(verbatim: self.entry.message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(self.entry.level.label), \(self.entry.category.rawValue), \(self.entry.message)"))
    }

    // MARK: - Level colour

    private var levelColor: Color {
        switch self.entry.level {
        case .trace, .debug:
            Color.textSecondary

        case .info:
            Color.textPrimary

        case .notice:
            Color.blue

        case .warning:
            Color.warningTint

        case .error, .fault:
            Color.red
        }
    }

    // MARK: - Timestamp formatting

    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    static func format(_ date: Date) -> String {
        self.timestampFormatter.string(from: date)
    }
}
