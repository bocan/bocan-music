import Library
import SwiftUI

// MARK: - LimitAndSortView

/// Controls for limit, multi-key sort, and live-update toggle.
///
/// Sorting is an ordered list of keys with priorities: the first row is the
/// primary sort, each following row breaks ties. `random` is exclusive — it is
/// only offered when there is a single sort key, and adding more keys is
/// disabled while it is selected.
struct LimitAndSortView: View {
    @Binding var limitSort: LimitSort

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized: "Limit & Sort")
                .font(Typography.title)
                .foregroundStyle(Color.textPrimary)

            // Sort rows (primary + tie-breakers)
            ForEach(self.limitSort.sortDescriptors.indices, id: \.self) { index in
                self.sortRow(index: index)
            }

            if self.canAddSortKey {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 80)
                    Button {
                        self.addSortKey()
                    } label: {
                        Label(L10n.string("Add sort key"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Add another sort key to break ties"))
                }
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

    // MARK: - Sort row

    @ViewBuilder
    private func sortRow(index: Int) -> some View {
        let descriptor = self.limitSort.sortDescriptors[index]
        HStack(spacing: 8) {
            Text(index == 0 ? L10n.string("Sort by") : L10n.string("then by"))
                .font(Typography.body)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 80, alignment: .trailing)

            Picker("", selection: self.keyBinding(index: index)) {
                ForEach(self.keyOptions, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .labelsHidden()
            .frame(minWidth: 140)
            .accessibilityLabel(L10n.string("Sort key"))

            if descriptor.key != .random {
                Toggle(isOn: self.ascendingBinding(index: index)) {
                    Image(systemName: descriptor.ascending ? "arrow.up" : "arrow.down")
                        .foregroundStyle(Color.textPrimary)
                }
                .toggleStyle(.button)
                .help(descriptor.ascending ? L10n.string("Ascending") : L10n.string("Descending"))
                .accessibilityLabel(L10n.string("Sort order"))
                .accessibilityValue(descriptor.ascending ? L10n.string("Ascending") : L10n.string("Descending"))
            }

            Spacer(minLength: 0)

            self.rowControls(index: index)
        }
    }

    /// Reorder + remove controls for a single sort row.
    @ViewBuilder
    private func rowControls(index: Int) -> some View {
        Button {
            self.move(from: index, by: -1)
        } label: {
            Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .disabled(index == 0)
        .help(L10n.string("Move sort key up"))
        .accessibilityLabel(L10n.string("Move sort key up"))

        Button {
            self.move(from: index, by: 1)
        } label: {
            Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .disabled(index == self.limitSort.sortDescriptors.count - 1)
        .help(L10n.string("Move sort key down"))
        .accessibilityLabel(L10n.string("Move sort key down"))

        Button(role: .destructive) {
            self.removeSortKey(at: index)
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .disabled(self.limitSort.sortDescriptors.count == 1)
        .help(L10n.string("Remove sort key"))
        .accessibilityLabel(L10n.string("Remove sort key"))
    }

    // MARK: - Sort mutation

    /// Keys available in a row's picker. `random` is exclusive, so it is only
    /// offered when there is a single sort key (adding more excludes it).
    private var keyOptions: [SortKey] {
        self.limitSort.sortDescriptors.count > 1
            ? SortKey.allCases.filter { $0 != .random }
            : SortKey.allCases
    }

    /// A new sort key can be added unless the sole key is `random` (exclusive).
    private var canAddSortKey: Bool {
        self.limitSort.sortDescriptors.first?.key != .random
    }

    private func keyBinding(index: Int) -> Binding<SortKey> {
        Binding(
            get: { self.limitSort.sortDescriptors[index].key },
            set: { self.limitSort.sortDescriptors[index].key = $0 }
        )
    }

    private func ascendingBinding(index: Int) -> Binding<Bool> {
        Binding(
            get: { self.limitSort.sortDescriptors[index].ascending },
            set: { self.limitSort.sortDescriptors[index].ascending = $0 }
        )
    }

    private func addSortKey() {
        let used = Set(self.limitSort.sortDescriptors.map(\.key))
        let next = SortKey.allCases.first { $0 != .random && !used.contains($0) } ?? .title
        self.limitSort.sortDescriptors.append(SmartSortDescriptor(key: next))
    }

    private func removeSortKey(at index: Int) {
        guard self.limitSort.sortDescriptors.count > 1,
              self.limitSort.sortDescriptors.indices.contains(index) else { return }
        self.limitSort.sortDescriptors.remove(at: index)
    }

    private func move(from index: Int, by offset: Int) {
        let target = index + offset
        guard self.limitSort.sortDescriptors.indices.contains(index),
              self.limitSort.sortDescriptors.indices.contains(target) else { return }
        self.limitSort.sortDescriptors.swapAt(index, target)
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

        case .trackNumber:
            L10n.string("Track Number")

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
