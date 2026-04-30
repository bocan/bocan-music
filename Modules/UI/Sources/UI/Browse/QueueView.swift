import AppKit
import Playback
import SwiftUI

// MARK: - QueueView

/// Shows the current playback queue with drag-to-reorder and context menu.
public struct QueueView: View {
    @ObservedObject public var vm: LibraryViewModel

    public init(vm: LibraryViewModel) {
        self.vm = vm
    }

    public var body: some View {
        QueueContentView(vm: self.vm)
    }
}

// MARK: - QueueContentView

/// Inner view that observes queue state via the `QueuePlayer`.
private struct QueueContentView: View {
    @ObservedObject var vm: LibraryViewModel
    /// Observed separately so the animated row indicator pauses when playback pauses.
    @ObservedObject var nowPlaying: NowPlayingViewModel
    @State private var items: [QueueItem] = []
    @State private var currentIndex: Int?
    @State private var unavailableIDs: Set<QueueItem.ID> = []

    init(vm: LibraryViewModel) {
        self.vm = vm
        self.nowPlaying = vm.nowPlaying
    }

    var body: some View {
        Group {
            if self.items.isEmpty {
                if self.vm.libraryRoots.isEmpty {
                    // Fresh install / no music folders configured: mirror the
                    // Albums and Artists empty states with an Add-Music-Folder CTA
                    // so this view doesn't dead-end users.
                    EmptyState(
                        symbol: "list.bullet.indent",
                        title: "Queue is Empty",
                        message: "Add a music folder to start building your library.",
                        actionLabel: "Add Music Folder"
                    ) {
                        Task { await self.vm.addFolderByPicker() }
                    }
                } else {
                    EmptyState(
                        symbol: "list.bullet.indent",
                        title: "Queue is Empty",
                        message: "Double-click a track, or right-click to add to queue."
                    )
                }
            } else {
                List {
                    ForEach(Array(self.items.enumerated()), id: \.element.id) { offset, item in
                        QueueRow(
                            item: item,
                            albumName: item.albumID.flatMap { self.vm.tracks.albumNames[$0] },
                            isCurrent: offset == self.currentIndex,
                            isPlaying: self.nowPlaying.isPlaying,
                            isUnavailable: self.unavailableIDs.contains(item.id),
                            position: offset
                        )
                        .contextMenu {
                            // Phase 5 audit M1: rich Up Next row context menu.
                            Button("Play From Here") {
                                Task {
                                    await self.vm.playFromQueueIndex(offset)
                                    await self.refreshQueue()
                                }
                            }
                            .disabled(self.unavailableIDs.contains(item.id))

                            Divider()

                            Button("Move to Top") {
                                Task {
                                    await self.vm.moveQueueItemToTop(id: item.id)
                                    await self.refreshQueue()
                                }
                            }
                            .disabled(offset == 0)

                            Button("Move to Bottom") {
                                Task {
                                    await self.vm.moveQueueItemToBottom(id: item.id)
                                    await self.refreshQueue()
                                }
                            }
                            .disabled(offset == self.items.count - 1)

                            Divider()

                            Button("Show in Finder") {
                                if let url = URL(string: item.fileURL) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                            .disabled(self.unavailableIDs.contains(item.id))

                            Button("Get Info") {
                                self.vm.tagEditorTrackIDs = [item.trackID]
                            }

                            if let albumID = item.albumID {
                                Button("Go to Album") {
                                    Task { await self.vm.selectDestination(.album(albumID)) }
                                }
                            }

                            if let artistID = item.artistID {
                                Button("Go to Artist") {
                                    Task { await self.vm.selectDestination(.artist(artistID)) }
                                }
                            }

                            Divider()

                            Button("Remove from Queue") {
                                Task {
                                    await self.vm.queuePlayer?.queue.remove(ids: Set([item.id]))
                                    await self.refreshQueue()
                                }
                            }
                        }
                        // Double-click row → play from this item. Mirrors the
                        // accessibilityHint on QueueRow so VoiceOver and pointer
                        // users get the same primary action. Skipped when the
                        // file is missing so we don't no-op silently.
                        .onTapGesture(count: 2) {
                            guard !self.unavailableIDs.contains(item.id) else { return }
                            Task {
                                await self.vm.playFromQueueIndex(offset)
                                await self.refreshQueue()
                            }
                        }
                    }
                    .onMove { from, to in
                        Task { await self.moveItems(from: from, to: to) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Up Next")
        .task { await self.refreshQueue() }
        .task { await self.observeQueueChanges() }
        .task { await self.observeUnavailableChanges() }
    }

    private func refreshQueue() async {
        guard let qp = vm.queuePlayer else { return }
        self.items = await qp.queue.items
        self.currentIndex = await qp.queue.currentIndex
        self.unavailableIDs = await qp.unavailableItemIDs()
    }

    private func observeQueueChanges() async {
        guard let queue = vm.queuePlayer?.queue else { return }
        for await _ in queue.changes {
            await self.refreshQueue()
        }
    }

    private func observeUnavailableChanges() async {
        guard let qp = vm.queuePlayer else { return }
        for await ids in qp.unavailableItemChanges {
            self.unavailableIDs = ids
        }
    }

    private func moveItems(from source: IndexSet, to destination: Int) async {
        guard let queue = vm.queuePlayer?.queue else { return }
        var newItems = self.items
        newItems.move(fromOffsets: source, toOffset: destination)
        // Replace queue with reordered items, preserve currentIndex into new order.
        let currentID = self.currentIndex.map { self.items[$0].id }
        await queue.replace(with: newItems, startAt: newItems.firstIndex { $0.id == currentID } ?? self.currentIndex ?? 0)
        await self.refreshQueue()
    }
}

// MARK: - QueueRow

private struct QueueRow: View {
    let item: QueueItem
    let albumName: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let isUnavailable: Bool
    let position: Int

    /// Best-effort display title: metadata title → decoded filename stem → raw last path component.
    private var displayTitle: String {
        if let t = item.title, !t.isEmpty { return t }
        let raw = self.item.fileURL.split(separator: "/").last.map(String.init) ?? self.item.fileURL
        return raw.removingPercentEncoding.map { url in
            // Strip extension for cleaner display.
            if let dot = url.lastIndex(of: ".") { return String(url[url.startIndex ..< dot]) }
            return url
        } ?? raw
    }

    private var displaySubtitle: String? {
        let parts = [item.artistName, self.albumName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    var body: some View {
        HStack(spacing: 0) {
            // Playing indicator — animated bars for the current track, warning glyph for
            // unavailable rows. Opacity-hidden otherwise; always hidden from VoiceOver.
            Group {
                if self.isUnavailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                } else {
                    PlayingBarsIndicator(isPlaying: self.isPlaying)
                }
            }
            .frame(width: 20)
            .opacity((self.isCurrent || self.isUnavailable) ? 1 : 0)
            .accessibilityHidden(true)

            // Title + artist/album
            VStack(alignment: .leading, spacing: 1) {
                Text(self.titleWithSuffix)
                    .font(self.isCurrent ? Typography.body.weight(.semibold) : Typography.body)
                    .foregroundStyle(self.titleColor)
                    .lineLimit(1)
                if let subtitle = self.displaySubtitle {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)

            // Genre
            if let genre = item.genre, !genre.isEmpty {
                Text(genre)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .frame(width: 80, alignment: .leading)
            } else {
                Spacer().frame(width: 80)
            }

            // Duration
            Text(Formatters.duration(self.item.duration))
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Color.textSecondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(self.isUnavailable ? 0.55 : 1.0)
        .help(self.isUnavailable ? "File missing — original location no longer exists" : "")
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.rowLabel)
        .accessibilityHint(self.isUnavailable
            ? "File is missing. Use the context menu to remove it from the queue."
            : "Double-tap to play from this item. Use the context menu to reorder, jump to album or artist, or remove from the queue.")
        .accessibilityAddTraits(self.isCurrent ? .isSelected : [])
    }

    private var titleWithSuffix: String {
        self.isUnavailable ? "\(self.displayTitle) (missing)" : self.displayTitle
    }

    private var titleColor: Color {
        if self.isUnavailable { return Color.textSecondary }
        return self.isCurrent ? Color.accentColor : Color.textPrimary
    }

    private var rowLabel: String {
        var parts = [self.isCurrent ? "Now playing: \(self.displayTitle)" : self.displayTitle]
        if self.isUnavailable { parts.append("file missing") }
        if let sub = self.displaySubtitle { parts.append(sub) }
        if let genre = item.genre, !genre.isEmpty { parts.append(genre) }
        parts.append(Formatters.duration(self.item.duration))
        return parts.joined(separator: ", ")
    }
}
