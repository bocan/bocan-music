// @preconcurrency: AVAudioFile lacks Sendable; it is opened, read for three
// numbers and released inside `init`, never stored.
@preconcurrency import AVFoundation
import Foundation

/// Audio properties from `AVAudioFile` for a file TagLib cannot parse.
///
/// TagLib has no AC-3 or E-AC-3 file type, so a raw Dolby file with no
/// container never reached the library: the scan logged
/// `scan.tag_read_failed` and imported nothing. AVFoundation opens those
/// files, so this reads the only facts such a file can give: duration,
/// sample rate and channel count. No tags, no cover art, no bit depth
/// (ADR-091 slice 3). `TagReader` is the one caller.
struct AVFoundationProperties: Sendable {
    let duration: Double
    let sampleRate: Int
    let channels: Int

    /// - Throws: AVFoundation's own error when it refuses the file too.
    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        self.sampleRate = Int(format.sampleRate)
        self.channels = Int(format.channelCount)
        self.duration = format.sampleRate > 0 ? Double(file.length) / format.sampleRate : 0
    }

    /// The tags for a file that carries none: the file's name as its title,
    /// plus these properties. Everything else stays nil.
    func tags(for url: URL) -> TrackTags {
        var tags = TrackTags(title: url.deletingPathExtension().lastPathComponent)
        tags.duration = self.duration
        tags.sampleRate = self.sampleRate > 0 ? self.sampleRate : nil
        tags.channels = self.channels > 0 ? self.channels : nil
        return tags
    }
}
