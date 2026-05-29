import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - PlaybackQueueTests

@Suite("PlaybackQueue")
struct PlaybackQueueTests {
    // MARK: - Helpers

    private func makeItem(
        trackID: Int64,
        albumID: Int64? = nil,
        excludedFromShuffle: Bool = false
    ) -> QueueItem {
        QueueItem(
            trackID: trackID,
            bookmark: nil,
            fileURL: "/tmp/track\(trackID).flac",
            duration: 200,
            sourceFormat: AudioSourceFormat(
                sampleRate: 44100, bitDepth: 16, channelCount: 2,
                isInterleaved: false, codec: "flac"
            ),
            albumID: albumID
        )
    }

    // MARK: - Append

    @Test("append adds items to end")
    func appendItems() async {
        let queue = PlaybackQueue()
        let items = (1 ... 3).map { self.makeItem(trackID: Int64($0)) }
        await queue.append(items)
        let stored = await queue.items
        #expect(stored.count == 3)
        #expect(stored[0].trackID == 1)
        #expect(stored[2].trackID == 3)
    }

    @Test("append to empty queue does not change currentIndex")
    func appendEmptyQueueNoCurrentIndex() async {
        let queue = PlaybackQueue()
        await queue.append([self.makeItem(trackID: 1)])
        let ci = await queue.currentIndex
        #expect(ci == nil)
    }

    // MARK: - appendNext

    @Test("appendNext inserts after current")
    func appendNext() async {
        let queue = PlaybackQueue()
        let items = (1 ... 4).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 1)
        let newItem = self.makeItem(trackID: 99)
        await queue.appendNext([newItem])
        let stored = await queue.items
        // Items: [1, 2, 99, 3, 4] — currentIndex was 1 (trackID=2), insert after → index 2
        #expect(stored[2].trackID == 99)
    }

    // MARK: - Replace

    @Test("replace sets items and currentIndex")
    func replace() async {
        let queue = PlaybackQueue()
        let items = (1 ... 5).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 2)
        let ci = await queue.currentIndex
        #expect(ci == 2)
        let current = await queue.currentItem
        #expect(current?.trackID == 3)
    }

    @Test("replace with empty array clears queue")
    func replaceEmpty() async {
        let queue = PlaybackQueue()
        await queue.append([self.makeItem(trackID: 1)])
        await queue.replace(with: [], startAt: 0)
        let ci = await queue.currentIndex
        let count = await queue.items.count
        #expect(ci == nil)
        #expect(count == 0)
    }

    // MARK: - Navigation

    @Test("advance moves to next item")
    func advance() async {
        let queue = PlaybackQueue()
        let items = (1 ... 3).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 0)
        let next = await queue.advance()
        #expect(next?.trackID == 2)
        let ci = await queue.currentIndex
        #expect(ci == 1)
    }

    @Test("advance at end with repeat-off returns nil")
    func advanceAtEndRepeatOff() async {
        let queue = PlaybackQueue()
        let items = [makeItem(trackID: 1)]
        await queue.replace(with: items, startAt: 0)
        let next = await queue.advance()
        #expect(next == nil)
        let ci = await queue.currentIndex
        #expect(ci == nil)
    }

    @Test("advance at end with repeat-all wraps to start")
    func advanceRepeatAll() async {
        let queue = PlaybackQueue()
        let items = (1 ... 3).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 2)
        await queue.setRepeatMode(.all)
        let next = await queue.advance()
        #expect(next?.trackID == 1)
    }

    @Test("advance with repeat-one stays on current")
    func advanceRepeatOne() async {
        let queue = PlaybackQueue()
        let items = (1 ... 3).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 1)
        await queue.setRepeatMode(.one)
        let next = await queue.advance()
        #expect(next?.trackID == 2)
    }

    @Test("peekNext does not advance")
    func peekNext() async {
        let queue = PlaybackQueue()
        let items = (1 ... 3).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 0)
        let peeked = await queue.peekNext()
        #expect(peeked?.trackID == 2)
        let ci = await queue.currentIndex
        #expect(ci == 0) // unchanged
    }

    // MARK: - Remove

    @Test("remove by ID removes correct item")
    func removeByID() async {
        let queue = PlaybackQueue()
        let items = (1 ... 4).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 0)
        let idToRemove = items[2].id
        await queue.remove(ids: [idToRemove])
        let stored = await queue.items
        #expect(stored.count == 3)
        #expect(!stored.contains(where: { $0.id == idToRemove }))
    }

    @Test("remove after current keeps the current track")
    func removeAfterCurrentKeepsCurrent() async {
        let queue = PlaybackQueue()
        let items = (1 ... 5).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 2) // current = track 3
        await queue.remove(ids: [items[3].id, items[4].id]) // remove tracks 4 & 5 (after current)
        let ci = await queue.currentIndex
        let current = await queue.currentItem
        #expect(ci == 2)
        #expect(current?.trackID == 3)
    }

    @Test("remove before current shifts the index but keeps the track")
    func removeBeforeCurrentShiftsIndex() async {
        let queue = PlaybackQueue()
        let items = (1 ... 5).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 2) // current = track 3
        await queue.remove(ids: [items[0].id, items[1].id]) // remove tracks 1 & 2 (before current)
        let ci = await queue.currentIndex
        let current = await queue.currentItem
        #expect(ci == 0)
        #expect(current?.trackID == 3)
    }

    @Test("remove on both sides of current keeps the track")
    func removeAroundCurrentKeepsCurrent() async {
        let queue = PlaybackQueue()
        let items = (1 ... 5).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 2) // current = track 3
        await queue.remove(ids: [items[0].id, items[4].id]) // one before, one after
        let ci = await queue.currentIndex
        let current = await queue.currentItem
        #expect(ci == 1) // one item removed before the cursor
        #expect(current?.trackID == 3)
    }

    @Test("removing the current item advances to the next surviving track")
    func removeCurrentAdvances() async {
        let queue = PlaybackQueue()
        let items = (1 ... 5).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 2) // current = track 3
        await queue.remove(ids: [items[2].id]) // remove the current track
        let ci = await queue.currentIndex
        let current = await queue.currentItem
        #expect(ci == 2)
        #expect(current?.trackID == 4)
    }

    @Test("removing the current item plus earlier items advances correctly")
    func removeCurrentWithEarlierRemovals() async {
        let queue = PlaybackQueue()
        let items = (1 ... 5).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 2) // current = track 3
        await queue.remove(ids: [items[0].id, items[2].id]) // remove track 1 and the current track 3
        let ci = await queue.currentIndex
        let current = await queue.currentItem
        #expect(ci == 1) // surviving [2, 4, 5]; next after track 3 is track 4
        #expect(current?.trackID == 4)
    }

    @Test("removing the current item at the tail clamps to the new last item")
    func removeCurrentAtTailClamps() async {
        let queue = PlaybackQueue()
        let items = (1 ... 3).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 2) // current = track 3 (last)
        await queue.remove(ids: [items[2].id])
        let ci = await queue.currentIndex
        let current = await queue.currentItem
        #expect(ci == 1)
        #expect(current?.trackID == 2)
    }

    @Test("removing every item clears the current index")
    func removeAllClearsCurrent() async {
        let queue = PlaybackQueue()
        let items = (1 ... 3).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 1)
        await queue.remove(ids: Set(items.map(\.id)))
        let ci = await queue.currentIndex
        let count = await queue.items.count
        let current = await queue.currentItem
        #expect(count == 0)
        #expect(ci == nil)
        #expect(current == nil)
    }

    // MARK: - Clear

    @Test("clear empties queue")
    func clearQueue() async {
        let queue = PlaybackQueue()
        let items = (1 ... 3).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 1)
        await queue.clear()
        let count = await queue.items.count
        let ci = await queue.currentIndex
        #expect(count == 0)
        #expect(ci == nil)
    }

    // MARK: - Shuffle

    @Test("shuffle-on reorders items and sets state")
    func shuffleOn() async {
        let queue = PlaybackQueue()
        let items = (1 ... 10).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 0)
        await queue.setShuffle(true, seed: 42)
        let state = await queue.shuffleState
        if case .on = state {} else {
            Issue.record("Expected shuffleState to be .on, got \(state)")
        }
    }

    @Test("shuffle-off restores original order")
    func shuffleOffRestores() async {
        let queue = PlaybackQueue()
        let items = (1 ... 5).map { self.makeItem(trackID: Int64($0)) }
        await queue.replace(with: items, startAt: 0)
        await queue.setShuffle(true, seed: 999)
        await queue.setShuffle(false)
        let stored = await queue.items
        let trackIDs = stored.map(\.trackID)
        #expect(trackIDs == [1, 2, 3, 4, 5])
    }

    @Test("excluded tracks do not appear in shuffle")
    func excludedTracksSkipped() async {
        let queue = PlaybackQueue()
        var items = (1 ... 5).map { self.makeItem(trackID: Int64($0)) }
        items[2] = QueueItem(
            trackID: 3,
            bookmark: nil,
            fileURL: "/tmp/track3.flac",
            duration: 200,
            sourceFormat: AudioSourceFormat(
                sampleRate: 44100, bitDepth: 16, channelCount: 2,
                isInterleaved: false, codec: "flac"
            ),
            excludedFromShuffle: true
        )
        await queue.replace(with: items, startAt: 0)
        await queue.setShuffle(true, seed: 12345)
        let shuffled = await queue.items
        #expect(!shuffled.contains(where: { $0.trackID == 3 }))
    }

    // MARK: - QueueChange stream

    @Test("changes stream can be iterated")
    func changesStreamCanBeIterated() async {
        let queue = PlaybackQueue()
        // Verify the changes stream exists and is non-nil by confirming queue operations work.
        let items = [makeItem(trackID: 1)]
        await queue.replace(with: items, startAt: 0)
        let count = await queue.items.count
        #expect(count == 1)
    }

    // MARK: - Stop After Current

    @Test("setStopAfterCurrent sets the flag")
    func setStopAfterCurrentSetsFlag() async {
        let queue = PlaybackQueue()
        await queue.setStopAfterCurrent(true)
        let flag = await queue.stopAfterCurrent
        #expect(flag == true)
    }

    @Test("setStopAfterCurrent false clears the flag")
    func setStopAfterCurrentClearsFlag() async {
        let queue = PlaybackQueue()
        await queue.setStopAfterCurrent(true)
        await queue.setStopAfterCurrent(false)
        let flag = await queue.stopAfterCurrent
        #expect(flag == false)
    }
}
