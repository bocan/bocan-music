import Foundation

/// A lock-free, single-producer / single-consumer ring buffer of `Float` samples.
///
/// Used by `FFmpegDecoder` to bridge the blocking C decode calls into the
/// async `read(into:)` interface without extra allocations per frame.
///
/// Thread-safety: safe for one writer and one reader operating concurrently.
/// Both the write head and read head are `nonisolated(unsafe)` to allow
/// unsynchronised reads from the other thread — this is intentional and correct
/// for an SPSC ring buffer.
public final class RingBuffer: @unchecked Sendable {
    // MARK: - Properties

    private let capacity: Int
    private let storage: UnsafeMutableBufferPointer<Float>
    private var writeHead = 0
    private var readHead = 0

    // MARK: - Computed properties

    /// Number of samples currently available to read.
    public var availableToRead: Int {
        (self.writeHead - self.readHead + self.capacity) & (self.capacity - 1)
    }

    /// Number of additional samples that can be written.
    public var availableToWrite: Int {
        self.capacity - 1 - self.availableToRead
    }

    // MARK: - Init / deinit

    public init(capacity: Int) {
        // Round capacity up to the next power of two for fast modulo via bit-mask.
        var size = 1
        while size < capacity {
            size <<= 1
        }
        self.capacity = size
        self.storage = .allocate(capacity: size)
        self.storage.initialize(repeating: 0)
    }

    // swiftlint:disable:next type_contents_order
    deinit {
        storage.deallocate()
    }

    // MARK: - API

    /// Write `count` floats from `source`. Returns number actually written.
    @discardableResult
    public func write(_ source: UnsafeBufferPointer<Float>, count: Int) -> Int {
        let toWrite = min(count, availableToWrite)
        guard toWrite > 0 else { return 0 }

        let mask = self.capacity - 1
        for i in 0 ..< toWrite {
            self.storage[(self.writeHead + i) & mask] = source[i]
        }
        self.writeHead = (self.writeHead + toWrite) & mask
        return toWrite
    }

    /// Read `count` floats into `dest`. Returns number actually read.
    @discardableResult
    public func read(_ dest: UnsafeMutableBufferPointer<Float>, count: Int) -> Int {
        let toRead = min(count, availableToRead)
        guard toRead > 0 else { return 0 }

        let mask = self.capacity - 1
        for i in 0 ..< toRead {
            dest[i] = self.storage[(self.readHead + i) & mask]
        }
        self.readHead = (self.readHead + toRead) & mask
        return toRead
    }

    /// Remove all pending samples.
    public func clear() {
        self.readHead = self.writeHead
    }
}
