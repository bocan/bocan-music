import Foundation

// MARK: - ShuffleStrategy

/// A type that can produce a shuffled permutation of a queue.
///
/// Implementors must be `Sendable` (value types or actors).
/// The `seed` parameter makes results deterministic — same seed, same output.
public protocol ShuffleStrategy: Sendable {
    func shuffled(_ items: [QueueItem], seed: UInt64) -> [QueueItem]
}

// MARK: - Xoshiro256StarStar RNG

/// Deterministic PRNG seeded from a `UInt64`.
///
/// Uses the xoshiro256** algorithm (Vigna & Blackman, 2019).
/// State is initialised via SplitMix64 so a simple seed produces
/// a well-mixed 256-bit state.
struct Xoshiro256StarStar: RandomNumberGenerator {
    /// The four 64-bit words of the generator's state.
    private struct State {
        var word0: UInt64
        var word1: UInt64
        var word2: UInt64
        var word3: UInt64
    }

    private var s: State

    init(seed: UInt64) {
        // SplitMix64 initializer — distributes the seed into 4 state words.
        var x = seed
        func sm64() -> UInt64 {
            x &+= 0x9E37_79B9_7F4A_7C15
            var z = x
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        self.s = State(word0: sm64(), word1: sm64(), word2: sm64(), word3: sm64())
    }

    mutating func next() -> UInt64 {
        let result = self.s.word1 &* 5
        let t = self.s.word1 << 17
        self.s.word2 ^= self.s.word0
        self.s.word3 ^= self.s.word1
        self.s.word1 ^= self.s.word2
        self.s.word0 ^= self.s.word3
        self.s.word2 ^= t
        self.s.word3 = (self.s.word3 << 45) | (self.s.word3 >> 19)
        return (result << 7) | (result >> 57)
    }
}
