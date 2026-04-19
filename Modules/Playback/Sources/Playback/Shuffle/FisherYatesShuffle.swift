import Foundation

// MARK: - FisherYatesShuffle

/// A uniform random shuffle using the Fisher-Yates (Knuth) algorithm.
///
/// Given the same seed this always produces the same permutation,
/// making the shuffle order reproducible and testable.
public struct FisherYatesShuffle: ShuffleStrategy {
    public init() {}

    public func shuffled(_ items: [QueueItem], seed: UInt64) -> [QueueItem] {
        guard items.count > 1 else { return items }
        var rng = Xoshiro256StarStar(seed: seed)
        var result = items
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            if i != j {
                result.swapAt(i, j)
            }
        }
        return result
    }
}
