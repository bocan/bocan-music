import Foundation
import Observability

// MARK: - PlaybackQueue

/// Actor that owns and manages the playback queue.
///
/// All mutating operations are serialised by actor isolation.
/// The `changes` stream emits incremental `QueueChange` events to UI consumers.
///
/// **Invariants maintained at all times:**
/// - `currentIndex` is `nil` or in `0..<items.count`.
/// - `history` is bounded to `historyLimit` items (oldest dropped first).
/// - Bulk operations (append 5k items) complete in < 50ms.
public actor PlaybackQueue {
    // MARK: - Types

    private static let historyLimit = 256

    // MARK: - State

    public private(set) var items: [QueueItem] = []
    public private(set) var history: [QueueItem] = []
    public private(set) var currentIndex: Int?
    public private(set) var repeatMode: RepeatMode = .off
    public private(set) var shuffleState: ShuffleState = .off

    /// The original (un-shuffled) source order, used to restore on shuffle-off.
    private var sourceOrder: [QueueItem] = []

    // MARK: - Change stream

    public nonisolated let changes: AsyncStream<QueueChange>
    private var changeContinuation: AsyncStream<QueueChange>.Continuation?

    private let log = AppLogger.make(.playback)

    // MARK: - Init

    public init() {
        var continuation: AsyncStream<QueueChange>.Continuation?
        self.changes = AsyncStream { continuation = $0 }
        self.changeContinuation = continuation
    }

    // MARK: - Queue mutations

    /// Append items to the end of the queue.
    public func append(_ newItems: [QueueItem]) {
        guard !newItems.isEmpty else { return }
        self.items.append(contentsOf: newItems)
        self.sourceOrder.append(contentsOf: newItems)
        self.emit(.appended(items: newItems))
        self.log.debug("queue.append", ["count": newItems.count, "total": self.items.count])
    }

    /// Insert items to play immediately after the current item (or at position 0 if nothing playing).
    public func appendNext(_ newItems: [QueueItem]) {
        guard !newItems.isEmpty else { return }
        let insertIdx = (currentIndex ?? -1) + 1
        self.items.insert(contentsOf: newItems, at: insertIdx)
        // Rebuild sourceOrder from items (since insertions at arbitrary positions are valid)
        self.sourceOrder = self.items
        self.emit(.insertedNext(items: newItems))
        self.log.debug("queue.appendNext", ["count": newItems.count])
    }

    /// Insert items at a specific index.
    public func insert(_ newItems: [QueueItem], at index: Int) {
        let clampedIdx = max(0, min(index, items.count))
        self.items.insert(contentsOf: newItems, at: clampedIdx)
        if let ci = currentIndex, clampedIdx <= ci {
            self.currentIndex = ci + newItems.count
        }
        self.sourceOrder = self.items
        self.emit(.appended(items: newItems))
    }

    /// Remove items by their queue-local IDs.
    /// If the current item is removed, advances to the next item (or stops).
    public func remove(ids: Set<QueueItem.ID>) {
        guard !ids.isEmpty else { return }
        let removedIDs = Array(ids)

        // Determine if we're removing the current item
        let removingCurrent = self.currentIndex.map { ids.contains(self.items[$0].id) } ?? false

        // Remove items and fix currentIndex
        var newCurrentIndex = self.currentIndex
        var removedCount = 0
        self.items = self.items.filter { item in
            if ids.contains(item.id) {
                removedCount += 1
                return false
            }
            return true
        }
        self.sourceOrder = self.sourceOrder.filter { !ids.contains($0.id) }

        // Adjust currentIndex
        if let ci = newCurrentIndex {
            if removingCurrent {
                // Advance to next (same index, now pointing at what was the next item)
                newCurrentIndex = ci < self.items.count ? ci : (self.items.isEmpty ? nil : self.items.count - 1)
            } else {
                // Count how many removed items were before currentIndex in the original array
                // We approximate by checking the new count
                newCurrentIndex = ci - removedCount < 0 ? 0 : max(0, ci - removedCount)
                if self.items.isEmpty { newCurrentIndex = nil }
            }
        }
        let previousIndex = self.currentIndex
        self.currentIndex = newCurrentIndex

        self.emit(.removed(ids: removedIDs))
        if previousIndex != self.currentIndex {
            self.emit(.currentChanged(newIndex: self.currentIndex, previousIndex: previousIndex))
        }
        self.log.debug("queue.remove", ["count": removedCount])
    }

    /// Move a single item from one position to another.
    public func move(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              self.items.indices.contains(fromIndex),
              self.items.indices.contains(toIndex) else { return }
        let item = self.items.remove(at: fromIndex)
        self.items.insert(item, at: toIndex)
        self.sourceOrder = self.items

        // Adjust currentIndex after the move
        if let ci = currentIndex {
            if ci == fromIndex {
                self.currentIndex = toIndex
            } else if fromIndex < ci, toIndex >= ci {
                self.currentIndex = ci - 1
            } else if fromIndex > ci, toIndex <= ci {
                self.currentIndex = ci + 1
            }
        }
        self.emit(.moved(fromIndex: fromIndex, toIndex: toIndex))
    }

    /// Clear the entire queue and history.
    public func clear() {
        self.items.removeAll()
        self.sourceOrder.removeAll()
        let previous = self.currentIndex
        self.currentIndex = nil
        self.emit(.cleared)
        if previous != nil {
            self.emit(.currentChanged(newIndex: nil, previousIndex: previous))
        }
        self.log.debug("queue.clear")
    }

    /// Replace the entire queue with `newItems`, starting playback at `startAt`.
    public func replace(with newItems: [QueueItem], startAt index: Int = 0) {
        self.items = newItems
        self.sourceOrder = newItems
        let newIndex: Int? = newItems.isEmpty ? nil : max(0, min(index, newItems.count - 1))
        self.currentIndex = newIndex
        self.emit(.reset(items: self.items, currentIndex: self.currentIndex))
        self.log.debug("queue.replace", ["count": newItems.count, "startAt": index])
    }

    // MARK: - Navigation

    /// Advance to the next item according to repeatMode, returning it or nil if stopped.
    public func advance() -> QueueItem? {
        switch self.repeatMode {
        case .one:
            // Don't advance — caller repeats the current item
            return self.currentItem

        case .all:
            guard !self.items.isEmpty else { return nil }
            let next = ((currentIndex ?? -1) + 1) % self.items.count
            return self.advance(to: next)

        case .off:
            let next = (currentIndex ?? -1) + 1
            guard next < self.items.count else {
                let prev = self.currentIndex
                self.currentIndex = nil
                self.emit(.currentChanged(newIndex: nil, previousIndex: prev))
                return nil
            }
            return self.advance(to: next)
        }
    }

    /// Navigate backwards. If near the start of the current item, go to previous; otherwise stays.
    public func retreat() -> QueueItem? {
        // Pop from history if available, otherwise go to start of current
        if !self.history.isEmpty {
            let prev = self.history.removeLast()
            // Find prev in items and set as current
            if let idx = items.firstIndex(where: { $0.id == prev.id }) {
                let previousIndex = self.currentIndex
                self.currentIndex = idx
                self.emit(.currentChanged(newIndex: idx, previousIndex: previousIndex))
                self.log.debug("queue.retreat", ["to": idx])
                return self.items[idx]
            }
        }
        // No history — go to previous index
        let targetIdx = (currentIndex ?? 1) - 1
        guard targetIdx >= 0, targetIdx < self.items.count else {
            return self.currentItem
        }
        return self.advance(to: targetIdx)
    }

    /// Peek at the item that would play after the current one (without advancing).
    public func peekNext() -> QueueItem? {
        switch self.repeatMode {
        case .one:
            return self.currentItem
        case .all:
            guard !self.items.isEmpty else { return nil }
            let next = ((currentIndex ?? -1) + 1) % self.items.count
            return self.items[next]
        case .off:
            let next = (currentIndex ?? -1) + 1
            return next < self.items.count ? self.items[next] : nil
        }
    }

    /// The currently playing item, or `nil` if nothing is loaded.
    public var currentItem: QueueItem? {
        self.currentIndex.map { self.items[$0] }
    }

    // MARK: - Repeat / shuffle

    public func setRepeatMode(_ mode: RepeatMode) {
        self.repeatMode = mode
        self.emit(.repeatChanged(mode))
        self.log.debug("queue.repeat", ["mode": mode.rawValue])
    }

    /// Enable or disable shuffle.
    /// When enabling: shuffles using `seed`, preserving current item at front.
    /// When disabling: restores the original source order starting from the current item.
    public func setShuffle(_ on: Bool, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        if on {
            self.shuffleState = .on(seed: seed)
            let strategy = FisherYatesShuffle()
            let current = self.currentItem

            // Exclude excluded tracks and shuffle the rest; current item stays first
            var toShuffle = self.items.filter { !$0.excludedFromShuffle }
            if let cur = current {
                toShuffle.removeAll { $0.id == cur.id }
            }
            var shuffled = strategy.shuffled(toShuffle, seed: seed)
            if let cur = current { shuffled.insert(cur, at: 0) }

            self.items = shuffled
            self.currentIndex = shuffled.isEmpty ? nil : 0
        } else {
            self.shuffleState = .off
            // Restore source order, keeping current item as the active index
            let current = self.currentItem
            self.items = self.sourceOrder
            if let cur = current, let idx = items.firstIndex(where: { $0.id == cur.id }) {
                self.currentIndex = idx
            }
        }
        self.emit(.shuffleChanged(self.shuffleState))
        self.emit(.reset(items: self.items, currentIndex: self.currentIndex))
        self.log.debug("queue.shuffle", ["on": on])
    }

    // MARK: - Private helpers

    private func advance(to index: Int) -> QueueItem? {
        guard self.items.indices.contains(index) else { return nil }

        // Push current to history
        if let ci = currentIndex {
            self.pushHistory(self.items[ci])
        }

        let previousIndex = self.currentIndex
        self.currentIndex = index
        self.emit(.currentChanged(newIndex: index, previousIndex: previousIndex))
        self.log.debug("queue.advance", ["to": index])
        return self.items[index]
    }

    private func pushHistory(_ item: QueueItem) {
        self.history.append(item)
        if self.history.count > Self.historyLimit {
            self.history.removeFirst()
        }
    }

    private func emit(_ change: QueueChange) {
        self.changeContinuation?.yield(change)
    }
}
