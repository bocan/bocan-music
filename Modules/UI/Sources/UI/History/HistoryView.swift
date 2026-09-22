import AppKit
import Persistence
import SwiftUI

// MARK: - HistoryView

/// The History destination (ADR-094): every recorded play, one row each,
/// newest first, under Recents in the sidebar.
///
/// Rows first, loading second, so a play that arrives while the page is open
/// keeps the table mounted (#543). Two empty states: no plays at all, and no
/// plays matching the query.
public struct HistoryView: View {
    public var vm: HistoryViewModel
    public var library: LibraryViewModel

    public init(vm: HistoryViewModel, library: LibraryViewModel) {
        self.vm = vm
        self.library = library
    }

    public var body: some View {
        Group {
            if !self.vm.rows.isEmpty {
                HistoryTable(rows: self.vm.rows, rowsVersion: self.vm.rowsVersion, actions: self.actions)
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
        // Keyed on the debounced query: a new term restarts the stream, and
        // leaving the page cancels it.
        .task(id: self.vm.debouncedQuery) {
            await self.vm.observe()
        }
    }

    // MARK: - Actions

    /// Bridges the table's play ids to the library. Each play is resolved to
    /// its song at action time, so the action sees current tags.
    private var actions: HistoryTableActions {
        let lib = self.library
        let vm = self.vm
        func tracks(for playIDs: [Int64]) async -> [Track] {
            var result: [Track] = []
            for playID in playIDs {
                if let track = await vm.track(forPlayID: playID) {
                    result.append(track)
                }
            }
            return result
        }
        return HistoryTableActions(
            playNow: { playID in
                Task {
                    // Just this song: a history row has no album or list
                    // around it to continue into.
                    guard let track = await vm.track(forPlayID: playID) else { return }
                    await lib.play(tracks: [track], startingAt: 0)
                }
            },
            playNext: { playIDs in
                Task { await lib.playNext(tracks: tracks(for: playIDs)) }
            },
            addToQueue: { playIDs in
                Task { await lib.addToQueue(tracks: tracks(for: playIDs)) }
            },
            goToArtist: { artistID in
                Task { await lib.selectDestination(.artist(artistID)) }
            },
            goToAlbum: { albumID in
                Task { await lib.selectDestination(.album(albumID)) }
            },
            showInFinder: { playID in
                // Synchronous, from the row, like every other list: the row
                // carries the file URL so no read sits between the menu
                // action and the reveal.
                guard let fileURL = vm.row(forPlayID: playID)?.fileURL,
                      let url = URL(string: fileURL) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            getInfo: { playIDs in
                Task {
                    let found = await tracks(for: playIDs)
                    guard !found.isEmpty else { return }
                    lib.showTagEditor(tracks: found)
                }
            }
        )
    }
}
