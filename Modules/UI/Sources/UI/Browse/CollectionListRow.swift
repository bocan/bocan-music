import SwiftUI

// MARK: - CollectionListRow

/// A single row in the Genres or Composers list: an accent avatar, the name, an
/// optional song-count subtitle, and a chevron. The two views rendered an
/// identical row inline; this is the shared version.
struct CollectionListRow: View {
    let name: String
    /// Avatar SF Symbol (`tag.fill` for genres, `music.note.list` for composers).
    let symbol: String
    let songCount: Int?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: self.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.name)
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)

                if let count = self.songCount, count > 0 {
                    Text(localized: "\(count) songs")
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - CollectionSort

/// The name / song-count sort shared by the Genres and Composers lists. Each
/// view keeps its own sort-order enum (persisted under its own key); this is
/// just the ordering algorithm both of them ran.
enum CollectionSort {
    /// Sorts `names` by song count (most first, name as the tiebreak) when
    /// `byName` is false, or alphabetically when `byName` is true.
    /// `localizedStandardCompare` orders numbers and diacritics naturally.
    static func apply(_ names: [String], byName: Bool, counts: [String: Int]) -> [String] {
        if byName {
            return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return names.sorted { lhs, rhs in
            let lcount = counts[lhs] ?? 0
            let rcount = counts[rhs] ?? 0
            if lcount != rcount { return lcount > rcount }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}
