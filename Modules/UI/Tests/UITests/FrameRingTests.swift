import Metal
import Testing
@testable import UI

// MARK: - FrameRingTests

/// Guards the triple-buffer ring. The slot arithmetic is tested as a pure
/// function (acquiring without releasing would unbalance the semaphore and crash
/// on deinit); the acquire/release round trip is a GPU smoke test that keeps the
/// semaphore balanced, skipped when no device is present.
@Suite("FrameRing")
@MainActor
struct FrameRingTests {
    @Test("nextIndex cycles through the slots")
    func nextIndexCycles() {
        #expect(FrameRing.nextIndex(0, slots: 3) == 1)
        #expect(FrameRing.nextIndex(1, slots: 3) == 2)
        #expect(FrameRing.nextIndex(2, slots: 3) == 0)
    }

    @Test("init allocates the requested shared buffers")
    func initAllocatesBuffers() {
        guard let device = MetalSupport.device else { return }
        let ring = FrameRing(device: device, bytesPerSlot: 256, slots: 3)
        #expect(ring != nil)
        #expect(ring?.slots == 3)
        #expect(ring?.bytesPerSlot == 256)
    }

    @Test("init rejects non-positive parameters")
    func initRejectsBadParameters() {
        guard let device = MetalSupport.device else { return }
        #expect(FrameRing(device: device, bytesPerSlot: 256, slots: 0) == nil)
        #expect(FrameRing(device: device, bytesPerSlot: 0, slots: 3) == nil)
    }

    @Test("acquire then release round-trips without deadlock and stays balanced")
    func acquireReleaseRoundTrip() throws {
        guard let device = MetalSupport.device, let queue = device.makeCommandQueue() else { return }
        let ring = try #require(FrameRing(device: device, bytesPerSlot: 64, slots: 2))

        // Run more frames than there are slots: if acquire/release were
        // unbalanced this would deadlock on the third acquire.
        for _ in 0 ..< 6 {
            let buffer = ring.acquire()
            #expect(buffer.length >= 64)
            guard let commandBuffer = queue.makeCommandBuffer() else {
                Issue.record("no command buffer")
                return
            }
            ring.release(when: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
    }
}
