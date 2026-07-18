import Persistence
import SwiftUI

// MARK: - ComposersView

/// Lists all composers in the library.  Selecting one pushes a track list.
public struct ComposersView: View {
    public var library: LibraryViewModel

    @State private var composers: [String] = []
    @State private var trackCounts: [String: Int] = [:]
    @State private var isLoading = true
    /// Persisted list sort order; defaults to composer name.
    @AppStorage("composers.sortOrder") private var sortOrder: ComposerSortOrder = .composerName

    public init(library: LibraryViewModel) {
        self.library = library
    }

    public var body: some View {
        Group {
            if self.isLoading {
                LoadingState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.composers.isEmpty {
                EmptyState(
                    symbol: "music.note.list",
                    title: L10n.string("No Composers"),
                    message: L10n.string("No composer tags found in your library.")
                )
            } else {
                self.composerList
            }
        }
        .navigationTitle(L10n.string("Composers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SortMenu(selection: self.$sortOrder, help: L10n.string("Choose how composers are sorted"))
            }
        }
        .task {
            let repo = TrackRepository(database: self.library.database)
            async let composersFetch = try? repo.allComposers()
            async let countsFetch = try? repo.composerTrackCounts()
            let allComposers = await composersFetch ?? []
            self.trackCounts = await countsFetch ?? [:]
            self.composers = self.sortedComposers(allComposers)
            self.isLoading = false
        }
        // Re-sort in place when the user changes the order (no refetch).
        .onChange(of: self.sortOrder) { _, _ in self.composers = self.sortedComposers(self.composers) }
    }

    /// Sorts `items` by the current ``sortOrder``. Song count falls back to
    /// composer name as a secondary key; `localizedStandardCompare` orders names
    /// naturally.
    private func sortedComposers(_ items: [String]) -> [String] {
        switch self.sortOrder {
        case .composerName:
            items.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        case .songCount:
            items.sorted { lhs, rhs in
                let lcount = self.trackCounts[lhs] ?? 0
                let rcount = self.trackCounts[rhs] ?? 0
                if lcount != rcount { return lcount > rcount }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }

    private var composerList: some View {
        ScrollViewReader { proxy in
            self.composerListContent
                // Re-center the last-visited composer when the list (re)appears,
                // so returning from a composer lands where the user left off (#349).
                .onAppear { self.restoreScrollPosition(proxy) }
                .onChange(of: self.composers) { _, _ in self.restoreScrollPosition(proxy) }
        }
    }

    /// Scrolls the last-visited composer back to the centre of the list.
    private func restoreScrollPosition(_ proxy: ScrollViewProxy) {
        guard let composer = self.library.lastVisitedComposer else { return }
        proxy.scrollTo(composer, anchor: .center)
    }

    private var composerListContent: some View {
        List(self.composers, id: \.self) { composer in
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(composer)
                        .font(Typography.body)
                        .foregroundStyle(Color.textPrimary)

                    if let count = self.trackCounts[composer], count > 0 {
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
            .contentShape(Rectangle())
            .onTapGesture {
                // Snapshot the visited composer so the list scrolls it back into
                // view when it's rebuilt on the way back (#349).
                self.library.lastVisitedComposer = composer
                Task { await self.library.selectDestination(.composer(composer)) }
            }
            .accessibilityLabel(composer)
            .accessibilityAddTraits(.isButton)
        }
    }
}
