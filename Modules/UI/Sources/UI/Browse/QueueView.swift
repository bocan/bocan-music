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
    @State private var items: [QueueItem] = []
    @State private var currentIndex: Int?

    var body: some View {
        Group {
            if self.items.isEmpty {
                EmptyState(
                    symbol: "list.bullet.indent",
                    title: "Queue is Empty",
                    message: "Double-click a track, or right-click to add to queue."
                )
            } else {
                List {
                    ForEach(Array(self.items.enumerated()), id: \.element.id) { offset, item in
                        QueueRow(item: item, isCurrent: offset == self.currentIndex, position: offset)
                            .contextMenu {
                                Button("Remove from Queue") {
                                    Task {
                                        await self.vm.queuePlayer?.queue.remove(ids: Set([item.id]))
                                        await self.refreshQueue()
                                    }
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
    }

    private func refreshQueue() async {
        guard let queue = vm.queuePlayer?.queue else { return }
        self.items = await queue.items
        self.currentIndex = await queue.currentIndex
    }

    private func observeQueueChanges() async {
        guard let queue = vm.queuePlayer?.queue else { return }
        for await _ in queue.changes {
            await self.refreshQueue()
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
    let isCurrent: Bool
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

    var body: some View {
        HStack(spacing: 0) {
            // Playing indicator
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
                .opacity(self.isCurrent ? 1 : 0)

            // Title + artist
            VStack(alignment: .leading, spacing: 1) {
                Text(self.displayTitle)
                    .font(self.isCurrent ? Typography.body.weight(.semibold) : Typography.body)
                    .foregroundStyle(self.isCurrent ? Color.accentColor : Color.textPrimary)
                    .lineLimit(1)
                if let artist = item.artistName, !artist.isEmpty {
                    Text(artist)
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
        .contentShape(Rectangle())
    }
}
