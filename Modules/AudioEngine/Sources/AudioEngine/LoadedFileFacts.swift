import AVFoundation
import Foundation
import Observability

// MARK: - LoadedFileFacts

/// What the engine can say about the local file it has open, read from the
/// file itself: its sample rate, its channels and its average bitrate.
///
/// A library track has these as scanned columns. A streamed song (Subsonic,
/// Jellyfin) has no library row, only the downloaded copy in the stream cache,
/// so the Now Playing badges read them from here instead (ADR-097 slice 7).
public struct LoadedFileFacts: Sendable, Equatable {
    /// Sample rate of the file in Hz.
    public let sampleRateHz: Int
    /// Channels in the file, before the engine's fold to stereo.
    public let channelCount: Int
    /// Average bitrate in kbps from the audio track's estimated data rate,
    /// which leaves out tags and cover art. Nil when the file does not say.
    public let bitrateKbps: Int?

    /// Creates the facts. The engine builds them; tests build them by hand.
    public init(sampleRateHz: Int, channelCount: Int, bitrateKbps: Int?) {
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.bitrateKbps = bitrateKbps
    }
}

// MARK: - AudioEngine + loaded file facts

/// The engine's description of the local file it has open.
public extension AudioEngine {
    /// Facts about the local file the current decoder plays, or nil for a
    /// network source or when nothing is loaded. The same gapless caveat as
    /// `currentStreamDetails` applies: for the last ~0.8 s of a transition this
    /// describes the incoming track.
    var currentFileFacts: LoadedFileFacts? {
        get async {
            guard let url = self.currentURL, url.isFileURL, let format = self.decoder?.sourceFormat else { return nil }
            let sampleRate = Int(format.sampleRate.rounded())
            let channels = Int(format.channelCount)
            guard sampleRate > 0, channels > 0 else { return nil }
            return await LoadedFileFacts(
                sampleRateHz: sampleRate,
                channelCount: channels,
                bitrateKbps: Self.averageBitrateKbps(of: url)
            )
        }
    }

    /// The first audio track's estimated data rate, in kbps. Read from the
    /// file's headers, so embedded cover art does not inflate it, as a
    /// size-over-length estimate would.
    private static func averageBitrateKbps(of url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
            let bitsPerSecond = try await track.load(.estimatedDataRate)
            let kbps = Int((Double(bitsPerSecond) / 1000).rounded())
            return kbps > 0 ? kbps : nil
        } catch {
            // The badge is left out; the format and sample rate still show.
            AppLogger.make(.audio).debug("engine.fileFacts.bitrateUnreadable", ["error": String(reflecting: error)])
            return nil
        }
    }
}
