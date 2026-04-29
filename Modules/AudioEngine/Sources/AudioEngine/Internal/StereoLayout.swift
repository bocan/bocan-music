// @preconcurrency: AVAudioChannelLayout lacks Sendable; this helper only
// reads its immutable fields.
// TODO: remove when AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation

/// Stereo channel layout helpers.
///
/// Centralises the one `AVAudioChannelLayout(layoutTag:)` call we ever need,
/// removing the `swiftlint:disable:next force_unwrapping` annotations that
/// were scattered through the engine and graph code.  The layout tag is
/// guaranteed-valid; the failable initialiser only fails for malformed tags.
enum StereoLayout {
    /// The standard stereo (L, R) channel layout.
    static let layout: AVAudioChannelLayout = {
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo) else {
            // kAudioChannelLayoutTag_Stereo is a built-in CoreAudio constant
            // and cannot fail to initialise on any supported platform.
            preconditionFailure("Failed to create stereo AVAudioChannelLayout")
        }
        return layout
    }()

    /// Build a Float32 non-interleaved stereo `AVAudioFormat` at the given rate.
    static func format(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channelLayout: self.layout
        )
    }
}
