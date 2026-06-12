import Metal

// MARK: - FrameRing

/// A small ring of per-frame `MTLBuffer`s guarded by a semaphore, for triple
/// buffering.
///
/// A CPU-written, GPU-read buffer races if the CPU starts writing frame N+1's
/// data while the GPU still reads frame N's. The ring hands out a different
/// buffer each frame and the semaphore blocks the CPU only when it gets `slots`
/// frames ahead of the GPU. `storageModeShared` suits Apple Silicon's unified
/// memory (this app is arm64-only): no copy between CPU and GPU.
final class FrameRing {
    let slots: Int
    let bytesPerSlot: Int

    private let buffers: [MTLBuffer]
    private let semaphore: DispatchSemaphore
    private var index = 0

    /// Allocates `slots` shared buffers of `bytesPerSlot` each. `nil` if any
    /// buffer allocation fails.
    init?(device: MTLDevice, bytesPerSlot: Int, slots: Int = 3) {
        guard slots > 0, bytesPerSlot > 0 else { return nil }
        var allocated = [MTLBuffer]()
        allocated.reserveCapacity(slots)
        for _ in 0 ..< slots {
            guard let buffer = device.makeBuffer(length: bytesPerSlot, options: .storageModeShared) else {
                return nil
            }
            allocated.append(buffer)
        }
        self.slots = slots
        self.bytesPerSlot = bytesPerSlot
        self.buffers = allocated
        self.semaphore = DispatchSemaphore(value: slots)
    }

    /// Waits until a slot's previous GPU work has finished, then returns that
    /// slot's buffer. Call exactly once per frame, before writing frame data.
    func acquire() -> MTLBuffer {
        self.semaphore.wait()
        let buffer = self.buffers[self.index]
        self.index = Self.nextIndex(self.index, slots: self.slots)
        return buffer
    }

    /// Signals the slot's semaphore when `commandBuffer` completes. Call exactly
    /// once per frame, before commit. The completion handler captures only the
    /// semaphore (thread-safe, `Sendable`), never renderer state, so it is safe
    /// to fire after the ring itself is gone.
    func release(when commandBuffer: MTLCommandBuffer) {
        let semaphore = self.semaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
    }

    /// Pure slot-advance arithmetic, exposed so it can be tested without touching
    /// the semaphore (acquiring without releasing would unbalance it).
    static func nextIndex(_ current: Int, slots: Int) -> Int {
        (current + 1) % slots
    }
}
