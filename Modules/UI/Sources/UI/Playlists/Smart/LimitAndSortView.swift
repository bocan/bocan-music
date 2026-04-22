import Library
import SwiftUI

// MARK: - LimitAndSortView

/// Controls for limit, sort-by, order, and live-update toggle.
struct LimitAndSortView: View {
    @Binding var limitSort: LimitSort

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Limit & Sort")
                .font(Typography.title)
                .foregroundStyle(Color.textPrimary)

            // Sort row
            HStack(spacing: 8) {
                Text("Sort by")
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
                .help(self.limitSort.ascending ? "Ascending" : "Descending")
            }

            // Limit row
            HStack(spacing: 8) {
                Toggle("Limit to", isOn: Binding(
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
                        Text("\(limit) tracks")
                    }
                }
            }

            // Live update toggle
            HStack(spacing: 8) {
                Color.clear.frame(width: 80)
                Toggle("Live update", isOn: self.$limitSort.liveUpdate)
                    .font(Typography.body)
                    .help("When enabled, the playlist updates automatically when library changes")
            }
        }
    }
}

// MARK: - SortKey display names

extension SortKey {
    var displayName: String {
        switch self {
        case .title:
            "Title"

        case .artist:
            "Artist"

        case .album:
            "Album"

        case .year:
            "Year"

        case .addedAt:
            "Date Added"

        case .lastPlayedAt:
            "Last Played"

        case .playCount:
            "Play Count"

        case .rating:
            "Rating"

        case .duration:
            "Duration"

        case .bpm:
            "BPM"

        case .random:
            "Random"
        }
    }
}
