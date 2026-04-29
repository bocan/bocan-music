@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - AudioTapTests

@Suite("AudioTap")
struct AudioTapTests {
    // MARK: - Install / remove lifecycle

    @Test("install is a no-op when called twice")
    func installIsDeduplicated() {
        guard audioOutputAvailable() else { return }
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        engine.prepare()

        let tap = AudioTap(bufferSize: 1024)
        tap.install(on: mixer)
        // Second install should not throw / crash.
        tap.install(on: mixer)
        tap.remove(from: mixer)
    }

    @Test("remove finishes the sample stream")
    func removeFinishesStream() async {
        guard audioOutputAvailable() else { return }
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        engine.prepare()

        let tap = AudioTap(bufferSize: 1024)
        tap.install(on: mixer)

        var gotNil = false
        let task = Task {
            var iter = tap.samples.makeAsyncIterator()
            // After remove(), the very next iteration should return nil.
            _ = await iter.next() // may or may not have a sample yet
            gotNil = await iter.next() == nil
        }

        tap.remove(from: mixer)
        await task.value
        #expect(gotNil, "Stream did not finish after remove(from:)")
    }

    // MARK: - Samples stream

    @Test("tap delivers AudioSamples with correct sampleRate")
    func tapDeliversSamplesWithSampleRate() async throws {
        guard audioOutputAvailable() else { return }

        let engine = AudioEngine()
        // Load a short fixture and tap immediately.
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)
        let stream = await engine.startTap()

        let collectTask = Task<[AudioSamples], Never> {
            var result: [AudioSamples] = []
            for await s in stream {
                result.append(s)
                if result.count >= 3 { break }
            }
            return result
        }

        try await engine.play()

        // Wait briefly for the tap to collect a few buffers.
        try await Task.sleep(for: .milliseconds(200))
        await engine.stopTap()

        let collected = await collectTask.value
        #expect(!collected.isEmpty, "No samples received")
        for sample in collected {
            #expect(sample.sampleRate > 0)
            #expect(!sample.mono.isEmpty)
            #expect(sample.rms.isFinite)
            #expect(sample.peak.isFinite)
            #expect(sample.peak >= 0)
        }

        await engine.stop()
    }

    @Test("stopTap finishes the stream returned by startTap")
    func stopTapFinishesStream() async {
        guard audioOutputAvailable() else { return }

        let engine = AudioEngine()
        let stream = await engine.startTap()

        var didFinish = false
        let consumer = Task {
            for await _ in stream {}
            didFinish = true
        }

        await engine.stopTap()
        await consumer.value
        #expect(didFinish)
    }
}

// MARK: - Helpers

private func audioOutputAvailable() -> Bool {
    DeviceRouter.defaultOutputDevice() != nil
}

private func fixtureURL(_ name: String) throws -> URL {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    return try #require(url, "Missing fixture: \(name)")
}
