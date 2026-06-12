import Foundation

// MARK: - SplitMix64

/// A small, fast, seedable pseudo-random generator (the SplitMix64 algorithm by
/// Steele, Lea, and Flood). Used by motion-heavy visualizers that need
/// deterministic particle layouts under a fixed seed so snapshot tests are
/// reproducible. A nil seed at the call site is resolved to a system-random
/// seed, giving non-deterministic placement in production.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
