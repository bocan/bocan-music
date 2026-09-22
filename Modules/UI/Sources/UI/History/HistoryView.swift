import AppKit
import Persistence
import SwiftUI

// MARK: - HistoryView

/// The History destination (ADR-094): every listen of a song in the library,
/// one row each, newest first, under Recents in the sidebar. Bòcan's own
/// plays and the Last.fm listens matched to a library song, with a Source
/// filter in the toolbar.
///
/// Rows first, loading second, so a play that arrives while the page is open
/// keeps the table mounted (#543). Two empty states: no listens at all, and
/// no listens matching the query.
public struct HistoryView: View {
    @Bindable public var vm: HistoryViewModel
    public var library: LibraryViewModel

    public init(vm: HistoryViewModel, library: LibraryViewModel) {
        self.vm = vm
        self.library = library
    }

    public var body: some View {
        Group {
            if !self.vm.rows.isEmpty {
                HistoryTable(
                    rows: self.vm.rows,
                    rowsVersion: self.vm.rowsVersion,
                    hasMore: self.vm.hasMore,
                    isLoading: self.vm.isLoading,
                    actions: self.actions
                )
            } else if self.vm.isLoading || !self.vm.hasLoaded {
                LoadingState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !self.vm.debouncedQuery.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass",
                    title: L10n.string("No Results"),
                    message: L10n.string("No plays match \u{201C}\(self.vm.debouncedQuery)\u{201D}.")
                )
                .accessibilityIdentifier(A11y.History.noResults)
            } else {
                EmptyState(
                    symbol: "clock.badge.checkmark",
                    title: L10n.string("No Plays Yet"),
                    message: L10n.string("Songs you listen to will be listed here, newest first.")
                )
                .accessibilityIdentifier(A11y.History.emptyState)
            }
        }
        .navigationTitle(L10n.string("History"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(L10n.string("Source"), selection: self.$vm.sourceFilter) {
                    Text(localized: "All").tag(PlayHistoryRepository.SourceFilter.all)
                    Text(localized: "Bòcan").tag(PlayHistoryRepository.SourceFilter.local)
                    Text(localized: "Last.fm").tag(PlayHistoryRepository.SourceFilter.imported)
                }
                .pickerStyle(.segmented)
                .help(L10n.string("Show plays recorded here, listens imported from Last.fm, or both."))
                .accessibilityIdentifier(A11y.History.sourcePicker)
            }
        }
        // Keyed on everything the stream depends on: a new term, source or
        // page restarts it, and leaving the page cancels it.
        .task(id: self.vm.observationKey) {
            await self.vm.observe()
        }
    }

    // MARK: - Actions

    /// Bridges the table's row keys to the library. Each listen is resolved
    /// to its song at action time, so the action sees current tags.
    private var actions: HistoryTableActions {
        let lib = self.library
        let vm = self.vm
        func tracks(for keys: [PlayHistoryRow.Key]) async -> [Track] {
            var result: [Track] = []
            for key in keys {
                if let track = await vm.track(forKey: key) {
                    result.append(track)
                }
            }
            return result
        }
        return HistoryTableActions(
            playNow: { key in
                Task {
                    // Just this song: a history row has no album or list
                    // around it to continue into.
                    guard let track = await vm.track(forKey: key) else { return }
                    await lib.play(tracks: [track], startingAt: 0)
                }
            },
            playNext: { keys in
                Task { await lib.playNext(tracks: tracks(for: keys)) }
            },
            addToQueue: { keys in
                Task { await lib.addToQueue(tracks: tracks(for: keys)) }
            },
            goToArtist: { artistID in
                Task { await lib.selectDestination(.artist(artistID)) }
            },
            goToAlbum: { albumID in
                Task { await lib.selectDestination(.album(albumID)) }
            },
            showInFinder: { key in
                // Synchronous, from the row, like every other list: the row
                // carries the file URL so no read sits between the menu
                // action and the reveal.
                guard let fileURL = vm.row(forKey: key)?.fileURL,
                      let url = URL(string: fileURL) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            getInfo: { keys in
                Task {
                    let found = await tracks(for: keys)
                    guard !found.isEmpty else { return }
                    lib.showTagEditor(tracks: found)
                }
            },
            loadMore: { vm.loadMore() }
        )
    }
}
