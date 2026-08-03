import Persistence
import SwiftUI

// MARK: - HourWeekdayHeatmap

/// When listening happens: hours across, weekdays down (Monday first), each
/// cell shaded by its share of the busiest cell.
struct HourWeekdayHeatmap: View {
    let cells: [LibraryListeningTimeReport.HourWeekdayCount]

    /// Monday-first display order in SQLite's `%w` numbering (0 = Sunday).
    private static let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]

    private var grid: [[Int]] {
        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for cell in self.cells where (0 ..< 7).contains(cell.weekday) && (0 ..< 24).contains(cell.hour) {
            counts[cell.weekday][cell.hour] = cell.count
        }
        return Self.weekdayOrder.map { counts[$0] }
    }

    var body: some View {
        let rows = self.grid
        let peak = max(1, rows.joined().max() ?? 1)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 2) {
                    Text(Self.weekdayLabel(index))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .leading)
                    self.rowCells(row, peak: peak)
                }
            }
            HStack(spacing: 2) {
                Spacer()
                    .frame(width: 22)
                self.hourAxis
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Heatmap of plays by hour of day and weekday"))
    }

    private func rowCells(_ row: [Int], peak: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 24, id: \.self) { hour in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.cellColor(row[hour], peak: peak))
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
            }
        }
    }

    /// Zero plays stay a faint neutral so the grid reads; anything above
    /// rides the visualizers' thermal ramp (navy through magenta and orange
    /// to white-hot), so "thermal" means one thing app-wide. Square-root
    /// scaling spreads the mid-tones: play counts skew hard toward a few
    /// busy evening cells, and a linear ramp leaves everything else cold.
    private static func cellColor(_ count: Int, peak: Int) -> Color {
        guard count > 0 else { return Color.primary.opacity(0.05) }
        let intensity = (Double(count) / Double(peak)).squareRoot()
        return PaletteResolver.thermalColor(magnitude: Float(intensity))
    }

    private var hourAxis: some View {
        HStack {
            ForEach([0, 6, 12, 18], id: \.self) { hour in
                Text(verbatim: String(hour))
                if hour != 18 {
                    Spacer()
                }
            }
            Text(verbatim: "23")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private static func weekdayLabel(_ displayRow: Int) -> String {
        Calendar.current.veryShortWeekdaySymbols[self.weekdayOrder[displayRow]]
    }
}

// MARK: - DiscoveryLineChart

/// New artists first heard per month, as a filled line over a continuous
/// month axis (empty months count as zero, which is rather the point).
struct DiscoveryLineChart: View {
    let months: [LibraryListeningTimeReport.MonthlyDiscovery]

    private var series: [Int] {
        guard let first = self.months.first, let last = self.months.last else { return [] }
        let start = first.year * 12 + first.month
        let span = last.year * 12 + last.month - start + 1
        guard span > 0 else { return [] }
        var values = Array(repeating: 0, count: span)
        for month in self.months {
            values[month.year * 12 + month.month - start] = month.newArtists
        }
        return values
    }

    private var peakMonth: LibraryListeningTimeReport.MonthlyDiscovery? {
        self.months.max { $0.newArtists < $1.newArtists }
    }

    var body: some View {
        let values = self.series
        if values.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                self.line(values)
                HStack {
                    Text(verbatim: Self.monthLabel(self.months.first))
                    Spacer()
                    if let peak = self.peakMonth {
                        Text(L10n.string(
                            "Peak: \(Self.monthLabel(peak)) · \(peak.newArtists.formatted()) new artists"
                        ))
                    }
                    Spacer()
                    Text(verbatim: Self.monthLabel(self.months.last))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string("Line chart of new artists first heard each month"))
        }
    }

    private func line(_ values: [Int]) -> some View {
        Canvas { context, size in
            let peak = max(1, values.max() ?? 1)
            let stepX = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: CGFloat(index) * stepX,
                    y: size.height - size.height * CGFloat(value) / CGFloat(peak)
                )
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            var area = path
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(.accentColor.opacity(0.15)))
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(height: 64)
    }

    /// "Mar 2011": a localized month symbol beside a year, formatter-style
    /// output rather than catalog copy.
    private static func monthLabel(_ month: LibraryListeningTimeReport.MonthlyDiscovery?) -> String {
        guard let month else { return "" }
        return "\(Calendar.current.shortMonthSymbols[month.month - 1]) \(String(month.year))"
    }
}
