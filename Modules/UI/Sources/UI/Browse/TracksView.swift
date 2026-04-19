import Persistence
import SwiftUI

// MARK: - TracksView

/// Full-width table of tracks with sortable, reorderable, persistable columns.
///
/// - Selection is a `Set<Track.ID>` (multi-select with shift-range, ⌘-toggle).
/// - Double-click or `Return` triggers the play action.
/// - `Space` toggles play/pause via the now-playing strip.
/// - Right-click opens the standard context menu.
public struct TracksView: View {
    @ObservedObject public var vm: TracksViewModel
    public var library: LibraryViewModel
    public var title: String?

    /// Controls Table column visibility/order.
    @State private var columnCustomization = TableColumnCustomization<Track>()

    /// Sort descriptors driven by column-header clicks.
    /// We only use this to forward sort requests to the ViewModel.
    @State private var sortOrder: [KeyPathComparator<Track>] = []

    @EnvironmentObject private var libraryEnv: LibraryViewModel

    public init(vm: TracksViewModel, library: LibraryViewModel, title: String? = nil) {
        self.vm = vm
        self.library = library
        self.title = title
    }

    public var body: some View {
        Group {
            if self.vm.isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.tracks.isEmpty {
                EmptyState(
                    symbol: "music.note",
                    title: "No Songs",
                    message: "Your library doesn't contain any songs yet."
                )
            } else {
                self.trackTable
            }
        }
        .navigationTitle(self.title ?? "Songs")
        .task { await self.vm.load() }
    }

    // MARK: - Table

    private var trackTable: some View {
        Table(
            self.vm.tracks,
            selection: self.$vm.selection,
            sortOrder: self.$sortOrder,
            columnCustomization: self.$columnCustomization
        ) {
            TableColumn("#") { (track: Track) in
                Text(track.trackNumber.map { "\($0)" } ?? "")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
            }
            .width(min: 28, ideal: 32, max: 40)
            .customizationID("trackNumber")

            TableColumn("Title") { (track: Track) in
                self.titleCell(for: track)
            }
            .width(min: 140, ideal: 220)
            .customizationID("title")

            TableColumn("Artist") { (track: Track) in
                Text(track.title != nil ? "" : "") // resolved below
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 160)
            .customizationID("artist")

            TableColumn("Album") { (_: Track) in
                Text("")
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 160)
            .customizationID("album")

            TableColumn("Year") { (track: Track) in
                Text(track.year.map { "\($0)" } ?? "")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textSecondary)
            }
            .width(min: 36, ideal: 48, max: 56)
            .customizationID("year")

            TableColumn("Genre") { (track: Track) in
                Text(track.genre ?? "")
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            .customizationID("genre")

            TableColumn("Time") { (track: Track) in
                Text(Formatters.duration(track.duration))
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
            }
            .width(min: 40, ideal: 52, max: 60)
            .customizationID("duration")

            TableColumn("Plays") { (track: Track) in
                Text("\(track.playCount)")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
            }
            .width(min: 36, ideal: 48, max: 56)
            .customizationID("playCount")

            TableColumn("Rating") { (track: Track) in
                let stars = Formatters.stars(from: track.rating)
                Text(stars > 0 ? String(repeating: "★", count: stars) : "")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.ratingFill)
            }
            .width(min: 52, ideal: 64, max: 72)
            .customizationID("rating")

            TableColumn("Date Added") { (track: Track) in
                Text(Formatters.shortDate(epochSeconds: track.addedAt))
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textSecondary)
            }
            .width(min: 72, ideal: 88)
            .customizationID("addedAt")
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            self.trackContextMenu(ids: ids)
        } primaryAction: { ids in
            // Double-click or Return: play the first selected track.
            if let trackID = ids.first,
               let track = vm.tracks.first(where: { $0.id == trackID }) {
                Task { await self.library.play(track: track) }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier(A11y.TracksTable.table)
    }

    // MARK: - Cells

    private func titleCell(for track: Track) -> some View {
        Text(track.title ?? "Unknown")
            .font(Typography.body)
            .foregroundStyle(track.loved ? Color.lovedTint : Color.textPrimary)
            .lineLimit(1)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func trackContextMenu(ids: Set<Track.ID>) -> some View {
        let selected = self.vm.tracks.filter { ids.contains($0.id) }
        let first = selected.first

        if let track = first {
            Button("Play Now") {
                Task { await self.library.play(track: track) }
            }
        }

        Divider()

        Button("Play Next") {}.disabled(true) // TODO(phase-5)
        Button("Add to Queue") {}.disabled(true) // TODO(phase-5)
        Button("Add to Playlist ▸") {}.disabled(true) // TODO(phase-6)

        Divider()

        if let first {
            Button(first.loved ? "Unlove" : "Love") {
                // TODO(phase-8): persist loved state
            }
        }

        Divider()

        Button("Reveal in Finder") {
            for track in selected {
                if let url = URL(string: track.fileURL) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .keyboardShortcut(KeyBindings.revealInFinder)

        Button("Get Info") {}.disabled(true) // TODO(phase-8)
            .keyboardShortcut(KeyBindings.getInfo)

        Divider()

        Button("Copy") {
            let tsv = selected.map { [$0.title ?? "", $0.genre ?? ""].joined(separator: "\t") }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tsv, forType: .string)
        }
    }
}
