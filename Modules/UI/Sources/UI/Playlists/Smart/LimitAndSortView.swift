import Library
import SwiftUI

// MARK: - LimitAndSortView

/// Controls for limit, sort-by, order, and live-update toggle.
struct LimitAndSortView: View {
    @Binding var limitSort: LimitSort

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized: "Limit & Sort")
                .font(Typography.title)
                .foregroundStyle(Color.textPrimary)

            // Sort row
            HStack(spacing: 8) {
                Text(localized: "Sort by")
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 80, alignment: .trailing)

                Picker("", selection: self.$limitSort.sortBy) {
                    ForEach(SortKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .frame(minWidth: 140)

                Toggle(isOn: self.$limitSort.ascending) {
                    Image(systemName: self.limitSort.ascending ? "arrow.up" : "arrow.down")
                        .foregroundStyle(Color.textPrimary)
                }
                .toggleStyle(.button)
                .help(self.limitSort.ascending ? L10n.string("Ascending") : L10n.string("Descending"))
                .accessibilityLabel(L10n.string("Sort order"))
                .accessibilityValue(self.limitSort.ascending ? L10n.string("Ascending") : L10n.string("Descending"))
            }

            // Limit row
            HStack(spacing: 8) {
                Toggle(L10n.string("Limit to"), isOn: Binding(
                    get: { self.limitSort.limit != nil },
                    set: { enabled in
                        self.limitSort.limit = enabled ? 25 : nil
                    }
                ))
                .font(Typography.body)
                .frame(width: 80, alignment: .trailing)

                if let limit = self.limitSort.limit {
                    Stepper(
                        value: Binding(
                            get: { limit },
                            set: { self.limitSort.limit = $0 }
                        ),
                        in: 1 ... 10000,
                        step: 5
                    ) {
                        Text(localized: "\(limit) tracks")
                    }
                }
            }

            // Live update toggle
            HStack(spacing: 8) {
                Color.clear.frame(width: 80)
                Toggle(L10n.string("Live update"), isOn: self.$limitSort.liveUpdate)
                    .font(Typography.body)
                    .help(L10n.string("When enabled, the playlist updates automatically when library changes"))
            }
        }
    }
}

// MARK: - SortKey display names

extension SortKey {
    var displayName: String {
        switch self {
        case .title:
            L10n.string("Title")

        case .artist:
            L10n.string("Artist")

        case .album:
            L10n.string("Album")

        case .year:
            L10n.string("Year")

        case .addedAt:
            L10n.string("Date Added")

        case .lastPlayedAt:
            L10n.string("Last Played")

        case .playCount:
            L10n.string("Play Count")

        case .rating:
            L10n.string("Rating")

        case .duration:
            L10n.string("Duration")

        case .bpm:
            L10n.string("BPM")

        case .random:
            L10n.string("Random")
        }
    }
}
