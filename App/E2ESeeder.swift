import AVFoundation
import Foundation
import Metadata
import Observability

// MARK: - E2ESeeder

/// Builds the on-disk fixture world for an E2E run (phase 28). The test
/// runner cannot write inside this app's container (macOS app-container
/// protection denies it unattended), so on an E2E launch the app itself
/// creates the run home and synthesizes a small fixture library: two
/// 60-second quiet sine-tone WAVs, tagged through the real `TagWriter` so
/// the scanner exercises its production read path.
enum E2ESeeder {
    private static let log = AppLogger.make(.app)

    /// Creates this run's home and fixture library, sweeping stale sibling
    /// runs first (the runner cannot delete them either). Must run before
    /// the database opens. No-op outside E2E mode; failures are logged and
    /// surface as an empty library in the journey, never as a crash.
    static func prepareHomeIfRequested() {
        guard let home = E2EEnvironment.home,
              let seed = E2EEnvironment.seedDirectory else { return }
        let fm = FileManager.default
        do {
            let root = E2EEnvironment.runsRoot
            if fm.fileExists(atPath: root.path) {
                let siblings = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                for stale in siblings where stale.lastPathComponent != home.lastPathComponent {
                    try? fm.removeItem(at: stale)
                    // Drop the stale run's isolated Settings suite too (the
                    // runner cannot, and it would otherwise leak plists).
                    UserDefaults().removePersistentDomain(
                        forName: E2EEnvironment.settingsSuiteName(forRunID: stale.lastPathComponent)
                    )
                }
            }
            try fm.createDirectory(at: seed, withIntermediateDirectories: true)
            // Idempotent across relaunches within one run: stable mtimes
            // mean the rescan on launch #2 sees no changes.
            for (name, frequency) in [("E2E Tone One", 220.0), ("E2E Tone Two", 330.0)]
                where !fm.fileExists(atPath: self.toneURL(named: name, in: seed).path) {
                try self.synthesizeTone(named: name, frequency: frequency, into: seed)
            }
        } catch {
            self.log.error("e2e.seed.failed", ["error": String(reflecting: error)])
        }
    }

    /// Writes a one-station `.m3u` dial file into this run's home pointing
    /// at `BOCAN_E2E_DIAL_FILE_URL`, if set. Must run after
    /// `prepareHomeIfRequested()` (which creates the run home). No-op
    /// outside E2E mode or without the env var; failures are logged, never
    /// surfaced as a crash.
    static func writeDialFileIfRequested() {
        guard let streamURL = E2EEnvironment.dialFileStreamURL,
              let dialFileURL = E2EEnvironment.dialFileURL else { return }
        let body = "#EXTM3U\n#EXTINF:-1,E2E Dial FM\n\(streamURL.absoluteString)\n"
        do {
            try body.write(to: dialFileURL, atomically: true, encoding: .utf8)
        } catch {
            self.log.error("e2e.dialFile.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: Tone synthesis

    private static func toneURL(named name: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(name).wav")
    }

    /// Writes a 60 s stereo 16-bit 44.1 kHz WAV of a quiet sine (long
    /// enough that transport assertions never race track end, quiet enough
    /// that local runs are not obnoxious), then tags it.
    private static func synthesizeTone(named name: String, frequency: Double, into dir: URL) throws {
        let url = self.toneURL(named: name, in: dir)
        let sampleRate = 44100.0
        let chunkFrames = 44100
        // Scope the AVAudioFile so it is closed (deinit flushes the header)
        // before TagLib rewrites the file.
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = AVAudioFrameCount(chunkFrames)
            for second in 0 ..< 60 {
                let base = Double(second * chunkFrames)
                for frame in 0 ..< chunkFrames {
                    let t = (base + Double(frame)) / sampleRate
                    let sample = Float(sin(2 * .pi * frequency * t) * 0.05)
                    for channel in 0 ..< 2 {
                        buffer.floatChannelData?[channel][frame] = sample
                    }
                }
                try file.write(from: buffer)
            }
        }
        try TagWriter().write(
            TrackTags(title: name, artist: "E2E Fixtures", album: "E2E"),
            to: url
        )
    }
}
