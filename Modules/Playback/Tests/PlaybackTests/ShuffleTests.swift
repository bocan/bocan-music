import Foundation
import Testing
@testable import Playback

// MARK: - ShuffleTests

@Suite("ShuffleStrategies")
struct ShuffleTests {
    private func makeItems(count: Int) -> [QueueItem] {
        (1 ... count).map { i in
            QueueItem(
                trackID: Int64(i),
                bookmark: nil,
                fileURL: "/tmp/track\(i).flac",
                duration: 200,
                sourceFormat: AudioSourceFormat(
                    sampleRate: 44100, bitDepth: 16, channelCount: 2,
                    isInterleaved: false, codec: "flac"
                )
            )
        }
    }

    // MARK: - FisherYatesShuffle

    @Test("FisherYates produces deterministic output for same seed")
    func fisherYatesDeterministic() {
        let items = self.makeItems(count: 20)
        let shuffle = FisherYatesShuffle()
        let result1 = shuffle.shuffled(items, seed: 42)
        let result2 = shuffle.shuffled(items, seed: 42)
        let ids1 = result1.map(\.id)
        let ids2 = result2.map(\.id)
        #expect(ids1 == ids2)
    }

    @Test("FisherYates different seeds produce different results")
    func fisherYatesDifferentSeeds() {
        let items = self.makeItems(count: 20)
        let shuffle = FisherYatesShuffle()
        let result1 = shuffle.shuffled(items, seed: 42)
        let result2 = shuffle.shuffled(items, seed: 99)
        // Different seeds should almost always produce different orders (may fail with tiny probability)
        #expect(result1.map(\.id) != result2.map(\.id))
    }

    @Test("FisherYates preserves all items (no duplicates, no drops)")
    func fisherYatesPreservesAllItems() {
        let items = self.makeItems(count: 100)
        let shuffle = FisherYatesShuffle()
        let result = shuffle.shuffled(items, seed: 1234)
        #expect(result.count == 100)
        let originalIDs = Set(items.map(\.id))
        let resultIDs = Set(result.map(\.id))
        #expect(originalIDs == resultIDs)
    }

    @Test("FisherYates with single item returns same item")
    func fisherYatesSingleItem() {
        let items = self.makeItems(count: 1)
        let shuffle = FisherYatesShuffle()
        let result = shuffle.shuffled(items, seed: 42)
        #expect(result.count == 1)
        #expect(result[0].id == items[0].id)
    }

    @Test("FisherYates with empty array returns empty")
    func fisherYatesEmpty() {
        let shuffle = FisherYatesShuffle()
        let result = shuffle.shuffled([], seed: 42)
        #expect(result.isEmpty)
    }

    // MARK: - SmartShuffle

    @Test("SmartShuffle excludes excluded-from-shuffle tracks")
    func smartShuffleExcludes() {
        var items = self.makeItems(count: 10)
        // Mark items with trackID 3, 7 as excluded.
        items[2] = QueueItem(
            trackID: 3, bookmark: nil,
            fileURL: "/tmp/track3.flac", duration: 200,
            sourceFormat: AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac"),
            excludedFromShuffle: true
        )
        items[6] = QueueItem(
            trackID: 7, bookmark: nil,
            fileURL: "/tmp/track7.flac", duration: 200,
            sourceFormat: AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac"),
            excludedFromShuffle: true
        )
        let shuffle = SmartShuffle()
        let result = shuffle.shuffled(items, seed: 42)
        #expect(!result.contains(where: { $0.trackID == 3 || $0.trackID == 7 }))
        #expect(result.count == 8)
    }

    @Test("SmartShuffle preserves non-excluded items")
    func smartShufflePreservesItems() {
        let items = self.makeItems(count: 20)
        let shuffle = SmartShuffle()
        let result = shuffle.shuffled(items, seed: 99)
        #expect(result.count == 20)
        let resultIDs = Set(result.map(\.id))
        let originalIDs = Set(items.map(\.id))
        #expect(resultIDs == originalIDs)
    }

    @Test("SmartShuffle with all excluded returns empty")
    func smartShuffleAllExcluded() {
        let items = (1 ... 5).map { i in
            QueueItem(
                trackID: Int64(i), bookmark: nil,
                fileURL: "/tmp/track\(i).flac", duration: 200,
                sourceFormat: AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac"),
                excludedFromShuffle: true
            )
        }
        let shuffle = SmartShuffle()
        let result = shuffle.shuffled(items, seed: 42)
        #expect(result.isEmpty)
    }

    @Test("SmartShuffle loved tracks appear in first half more often than unloved")
    func smartShuffleWeightsLoved() {
        // Create 10 tracks where only track 1 is loved. Run shuffle 100 times.
        // Track 1 should appear in first 5 positions more than 50% of the time.
        let loved = QueueItem(
            trackID: 1, bookmark: nil,
            fileURL: "/tmp/track1.flac", duration: 200,
            sourceFormat: AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac"),
            loved: true
        )
        var items: [QueueItem] = [loved]
        for i in 2 ... 10 {
            items.append(QueueItem(
                trackID: Int64(i), bookmark: nil,
                fileURL: "/tmp/track\(i).flac", duration: 200,
                sourceFormat: AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac")
            ))
        }
        let shuffle = SmartShuffle()
        var firstHalfCount = 0
        for seed in UInt64(0) ..< 100 {
            let result = shuffle.shuffled(items, seed: seed)
            if let idx = result.firstIndex(where: { $0.trackID == 1 }), idx < 5 {
                firstHalfCount += 1
            }
        }
        // With a love bonus, should appear in first half significantly more than ~50%
        #expect(firstHalfCount > 50)
    }
}

// MARK: - Xoshiro256StarStar Tests

@Suite("Xoshiro256StarStar")
struct XoshiroTests {
    @Test("same seed produces same sequence")
    func deterministicSequence() {
        var rng1 = Xoshiro256StarStar(seed: 42)
        var rng2 = Xoshiro256StarStar(seed: 42)
        for _ in 0 ..< 100 {
            #expect(rng1.next() == rng2.next())
        }
    }

    @Test("different seeds produce different sequences")
    func differentSeeds() {
        var rng1 = Xoshiro256StarStar(seed: 1)
        var rng2 = Xoshiro256StarStar(seed: 2)
        var anyDifferent = false
        for _ in 0 ..< 10 {
            if rng1.next() != rng2.next() {
                anyDifferent = true
                break
            }
        }
        #expect(anyDifferent)
    }
}
