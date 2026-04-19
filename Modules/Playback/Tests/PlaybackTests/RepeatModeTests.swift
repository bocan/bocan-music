import Foundation
import Testing
@testable import Playback

// MARK: - RepeatModeTests

@Suite("RepeatMode")
struct RepeatModeTests {
    private func makeQueue(count: Int, startAt: Int = 0) async -> PlaybackQueue {
        let queue = PlaybackQueue()
        let items = (1 ... count).map { i in
            QueueItem(
                trackID: Int64(i),
                bookmark: nil,
                fileURL: "/tmp/t\(i).flac",
                duration: 200,
                sourceFormat: AudioSourceFormat(
                    sampleRate: 44100, bitDepth: 16, channelCount: 2,
                    isInterleaved: false, codec: "flac"
                )
            )
        }
        await queue.replace(with: items, startAt: startAt)
        return queue
    }

    // MARK: - .off

    @Test(".off stops at end of queue")
    func offStopsAtEnd() async {
        let queue = await makeQueue(count: 3, startAt: 2)
        await queue.setRepeatMode(.off)
        let result = await queue.advance()
        #expect(result == nil)
        let ci = await queue.currentIndex
        #expect(ci == nil)
    }

    @Test(".off advance in middle works normally")
    func offAdvanceMid() async {
        let queue = await makeQueue(count: 3, startAt: 0)
        await queue.setRepeatMode(.off)
        let next = await queue.advance()
        #expect(next?.trackID == 2)
    }

    // MARK: - .all

    @Test(".all wraps from last to first")
    func allWraps() async {
        let queue = await makeQueue(count: 3, startAt: 2)
        await queue.setRepeatMode(.all)
        let next = await queue.advance()
        #expect(next?.trackID == 1)
        let ci = await queue.currentIndex
        #expect(ci == 0)
    }

    @Test(".all advance in middle works normally")
    func allAdvanceMid() async {
        let queue = await makeQueue(count: 3, startAt: 1)
        await queue.setRepeatMode(.all)
        let next = await queue.advance()
        #expect(next?.trackID == 3)
    }

    @Test(".all peekNext wraps correctly")
    func allPeekNextWraps() async {
        let queue = await makeQueue(count: 3, startAt: 2)
        await queue.setRepeatMode(.all)
        let peeked = await queue.peekNext()
        #expect(peeked?.trackID == 1)
    }

    // MARK: - .one

    @Test(".one stays on current item when advancing")
    func oneStaysOnCurrent() async {
        let queue = await makeQueue(count: 3, startAt: 1)
        await queue.setRepeatMode(.one)
        let item = await queue.advance()
        #expect(item?.trackID == 2) // stays at index 1 (trackID 2)
        let ci = await queue.currentIndex
        #expect(ci == 1)
    }

    @Test(".one peekNext returns current item")
    func onePeekNextReturnsCurrent() async {
        let queue = await makeQueue(count: 3, startAt: 0)
        await queue.setRepeatMode(.one)
        let peeked = await queue.peekNext()
        #expect(peeked?.trackID == 1)
    }

    // MARK: - Mode change emission

    @Test("setRepeatMode emits change event")
    func modeChangeEmitted() async {
        let queue = PlaybackQueue()
        await queue.setRepeatMode(.all)
        let mode = await queue.repeatMode
        #expect(mode == .all)
    }
}
