import Persistence
import SwiftUI

// MARK: - CollectionShapeStyle

/// Shared formatting for the Collection Shape tab's charts and rows.
enum CollectionShapeStyle {
    /// 1990 -> "1990s". String interpolation keeps digit grouping out of years.
    static func decadeLabel(_ decade: Int) -> String {
        L10n.string("\(String(decade))s")
    }

    /// A share of `total` as a whole percent ("23%"); "0%" when there is no total.
    static func percent(_ value: Double, of total: Double) -> String {
        guard total > 0 else { return 0.formatted(.percent) }
        return (value / total).formatted(.percent.precision(.fractionLength(0)))
    }

    /// One colour per decade, all from the accent: oldest lightest, newest
    /// solid, so the two strips read as one chronology.
    static func color(index: Int, of count: Int) -> Color {
        guard count > 1 else { return .accentColor }
        let fraction = Double(index) / Double(count - 1)
        return Color.accentColor.opacity(0.35 + 0.65 * fraction)
    }
}

// MARK: - YearHistogramChart

/// A compact release-year histogram: one bar per calendar year across the
/// plausible span, drawn in a Canvas so a century of bars stays cheap.
struct YearHistogramChart: View {
    let years: [LibraryCollectionShapeReport.YearCount]

    private var span: ClosedRange<Int>? {
        guard let first = self.years.first?.year, let last = self.years.last?.year, last >= first else {
            return nil
        }
        return first ... last
    }

    private var peak: LibraryCollectionShapeReport.YearCount? {
        self.years.max { $0.count < $1.count }
    }

    var body: some View {
        let peakCount = self.peak?.count ?? 0
        if let span, let peak, peakCount != 0 {
            VStack(alignment: .leading, spacing: 4) {
                self.bars(span: span, peakCount: peakCount)
                HStack {
                    Text(verbatim: String(span.lowerBound))
                    Spacer()
                    Text(L10n.string("Peak: \(String(peak.year)) · \(peak.count.formatted()) songs"))
                    Spacer()
                    Text(verbatim: String(span.upperBound))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string(
                "Release year histogram from \(String(span.lowerBound)) to \(String(span.upperBound)), peaking in \(String(peak.year))"
            ))
        }
    }

    private func bars(span: ClosedRange<Int>, peakCount: Int) -> some View {
        Canvas { context, size in
            let counts = Dictionary(uniqueKeysWithValues: self.years.map { ($0.year, $0.count) })
            let slotWidth = size.width / CGFloat(span.count)
            let barWidth = max(1, slotWidth - 1)
            for (index, year) in span.enumerated() {
                guard let count = counts[year], count > 0 else { continue }
                let height = max(2, size.height * CGFloat(count) / CGFloat(peakCount))
                let rect = CGRect(
                    x: CGFloat(index) * slotWidth,
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.85)))
            }
        }
        .frame(height: 64)
    }
}

// MARK: - DecadeStripsChart

/// Ownership and listening as two aligned proportional strips, one segment
/// per decade in shared colours. The visual disagreement between the rows is
/// the point: the gap between what you own and what you play.
struct DecadeStripsChart: View {
    let decades: [LibraryCollectionShapeReport.DecadeShare]

    private var ownedTotal: Double {
        self.decades.reduce(0) { $0 + $1.ownedSeconds }
    }

    private var playedTotal: Double {
        self.decades.reduce(0) { $0 + $1.playedSeconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.strip(label: L10n.string("Owned"), total: self.ownedTotal, value: \.ownedSeconds)
            if self.playedTotal > 0 {
                self.strip(label: L10n.string("Played"), total: self.playedTotal, value: \.playedSeconds)
            } else {
                Text(localized: "Nothing played yet, so there is no listening strip to compare.")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            self.legend
        }
    }

    private func strip(
        label: String,
        total: Double,
        value: KeyPath<LibraryCollectionShapeReport.DecadeShare, Double>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(Array(self.decades.enumerated()), id: \.element.id) { index, decade in
                        Rectangle()
                            .fill(CollectionShapeStyle.color(index: index, of: self.decades.count))
                            .frame(width: self.segmentWidth(
                                decade[keyPath: value],
                                of: total,
                                in: proxy.size.width
                            ))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 14)
        }
    }

    private func segmentWidth(_ value: Double, of total: Double, in width: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return max(0, width * CGFloat(value / total))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(self.decades.enumerated()), id: \.element.id) { index, decade in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CollectionShapeStyle.color(index: index, of: self.decades.count))
                        .frame(width: 10, height: 10)
                    Text(CollectionShapeStyle.decadeLabel(decade.decade))
                        .frame(width: 48, alignment: .leading)
                    Text(self.shareText(decade))
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    private func shareText(_ decade: LibraryCollectionShapeReport.DecadeShare) -> String {
        let owned = CollectionShapeStyle.percent(decade.ownedSeconds, of: self.ownedTotal)
        guard self.playedTotal > 0 else {
            return L10n.string("\(owned) of the library")
        }
        let played = CollectionShapeStyle.percent(decade.playedSeconds, of: self.playedTotal)
        return L10n.string("\(owned) of the library · \(played) of listening")
    }
}
