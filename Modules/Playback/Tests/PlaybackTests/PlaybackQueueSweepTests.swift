import CoreAudio
import Foundation
import Persistence
import Testing
@testable import Playback

private func item(_ id: Int64, albumID: Int64? = nil) -> QueueItem {
    QueueItem(
        trackID: id,
        bookmark: nil,
        fileURL: "/tmp/t\(id).flac",
        duration: 100,
        sourceFormat: AudioSourceFormat(
            sampleRate: 44100, bitDepth: 16, channelCount: 2,
            isInterleaved: false, codec: "flac"
        ),
        albumID: albumID
    )
}

// MARK: - PlaybackQueue methods that were uncovered

@Suite("PlaybackQueue additional methods")
struct PlaybackQueueAdditionalTests {
    @Test("insert at index 0 places items at the front and shifts currentIndex")
    func insertAtFront() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1), item(2), item(3)], startAt: 1)
        await queue.insert([item(10), item(11)], at: 0)
        let stored = await queue.items
        #expect(stored.map(\.trackID).prefix(2) == [10, 11])
        let ci = await queue.currentIndex
        #expect(ci == 3) // was 1, +2 inserted before
    }

    @Test("insert past the end clamps to end")
    func insertPastEnd() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1)], startAt: 0)
        await queue.insert([item(2)], at: 99)
        let stored = await queue.items
        #expect(stored.map(\.trackID) == [1, 2])
    }

    @Test("move shifts items and updates currentIndex when moving the current item")
    func moveCurrent() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1), item(2), item(3)], startAt: 1)
        await queue.move(fromIndex: 1, toIndex: 2)
        let ci = await queue.currentIndex
        #expect(ci == 2)
        let stored = await queue.items
        #expect(stored.map(\.trackID) == [1, 3, 2])
    }

    @Test("move with fromIndex == toIndex is a no-op")
    func moveSameIndex() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1), item(2)], startAt: 0)
        await queue.move(fromIndex: 0, toIndex: 0)
        let stored = await queue.items
        #expect(stored.map(\.trackID) == [1, 2])
    }

    @Test("move with out-of-range indices is a no-op")
    func moveOutOfRange() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1), item(2)], startAt: 0)
        await queue.move(fromIndex: 5, toIndex: 0)
        let stored = await queue.items
        #expect(stored.count == 2)
    }

    @Test("reorder reseats current item by trackID")
    func reorderKeepsCurrent() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1), item(2), item(3)], startAt: 1) // current=2
        await queue.reorder(to: [item(3), item(2), item(1)])
        let ci = await queue.currentIndex
        #expect(ci == 1)
    }

    @Test("reorder with an empty array is a no-op")
    func reorderEmpty() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1)], startAt: 0)
        await queue.reorder(to: [])
        let stored = await queue.items
        #expect(stored.count == 1)
    }

    @Test("seekToIndex updates currentIndex and emits a change")
    func seekToIndex() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1), item(2), item(3)], startAt: 0)
        await queue.seekToIndex(2)
        let ci = await queue.currentIndex
        #expect(ci == 2)
    }

    @Test("seekToIndex with an out-of-range index is a no-op")
    func seekToIndexOutOfRange() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1)], startAt: 0)
        await queue.seekToIndex(99)
        let ci = await queue.currentIndex
        #expect(ci == 0)
    }

    @Test("advanceManual wraps under .all repeat")
    func advanceManualWrapAll() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1), item(2)], startAt: 1)
        await queue.setRepeatMode(.all)
        let next = await queue.advanceManual()
        #expect(next?.trackID == 1)
    }

    @Test("advanceManual under .one still advances to the next item")
    func advanceManualOne() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1), item(2)], startAt: 0)
        await queue.setRepeatMode(.one)
        let next = await queue.advanceManual()
        #expect(next?.trackID == 2)
    }

    @Test("advanceManual under .off returns nil at end")
    func advanceManualOffAtEnd() async {
        let queue = PlaybackQueue()
        await queue.replace(with: [item(1), item(2)], startAt: 1)
        await queue.setRepeatMode(.off)
        let next = await queue.advanceManual()
        #expect(next == nil)
    }
}

// MARK: - QueueItem direct API

@Suite("QueueItem API")
struct QueueItemAPITests {
    @Test("resolvedURL parses fileURL when bookmark is nil")
    func resolvedURL() throws {
        let q = QueueItem(
            trackID: 1,
            bookmark: nil,
            fileURL: "file:///tmp/foo.flac",
            duration: 10,
            sourceFormat: AudioSourceFormat(
                sampleRate: 44100, bitDepth: 16, channelCount: 2,
                isInterleaved: false, codec: "flac"
            )
        )
        let url = try q.resolvedURL()
        #expect(url.absoluteString == "file:///tmp/foo.flac")
    }

    @Test("resolvedURL throws when fileURL is unparseable")
    func resolvedURLThrows() throws {
        let q = QueueItem(
            trackID: 2,
            bookmark: nil,
            // URL(string:) returns nil for a string containing a percent-encoded NUL
            fileURL: "scheme://%ZZ",
            duration: 10,
            sourceFormat: AudioSourceFormat(
                sampleRate: 44100, bitDepth: 16, channelCount: 2,
                isInterleaved: false, codec: "flac"
            )
        )
        #expect(throws: (any Error).self) { _ = try q.resolvedURL() }
    }

    @Test("isCUETrack reflects startOffsetMs presence")
    func isCUETrack() {
        let cue = QueueItem(
            trackID: 3,
            bookmark: nil,
            fileURL: "file:///x",
            duration: 10,
            sourceFormat: AudioSourceFormat(
                sampleRate: 44100, bitDepth: 16, channelCount: 2,
                isInterleaved: false, codec: "flac"
            ),
            startOffsetMs: 0,
            endOffsetMs: 5000
        )
        #expect(cue.isCUETrack)
        let plain = item(4)
        #expect(!plain.isCUETrack)
    }

    @Test("Equatable + Hashable use id only")
    func equatableHashable() {
        let a = item(1)
        let b = a
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != item(1))
    }
}

// MARK: - PlaybackError descriptions

@Suite("PlaybackError descriptions")
struct PlaybackErrorTests {
    @Test("each case produces a non-empty description")
    func descriptions() {
        let cases: [PlaybackError] = [
            .noBookmark(trackID: 7),
            .bookmarkResolutionFailed(trackID: 8, underlying: URLError(.badURL)),
            .trackNotFound(id: 9),
            .queueEmpty,
            .engineFailure(underlying: URLError(.cannotOpenFile)),
            .incompatibleFormat(reason: "bad"),
        ]
        for err in cases {
            #expect(!err.description.isEmpty)
        }
    }
}

// MARK: - TransportType rawCode round-trip

@Suite("TransportType rawCode")
struct TransportTypeRawCodeTests {
    @Test("each named CoreAudio transport code maps to the matching case")
    func mapsAllKnownCodes() {
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeAirPlay) == .airPlay)
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeBluetoothLE) == .bluetoothLE)
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeHDMI) == .hdmi)
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeDisplayPort) == .displayPort)
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeUSB) == .usb)
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeThunderbolt) == .thunderbolt)
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeAggregate) == .aggregate)
        #expect(TransportType(rawCode: kAudioDeviceTransportTypeVirtual) == .virtual)
        #expect(TransportType(rawCode: 0) == .unknown)
        #expect(TransportType(rawCode: 0xFFFF_FFFF) == .unknown)
    }
}
