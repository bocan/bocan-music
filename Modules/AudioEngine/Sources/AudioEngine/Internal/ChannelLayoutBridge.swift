@preconcurrency import AVFoundation
import CFFmpeg
import Foundation

// MARK: - ChannelLayoutBridge

/// Describes an FFmpeg channel layout as a CoreAudio one, channel by channel,
/// so `FFmpegDecoder` can hand the engine a multichannel buffer in the file's
/// own order and `FormatConverter` can fold it (#522).
///
/// A description-built layout folds exactly like a tagged one: measured on
/// macOS 26, a 5.1 built from labels and `kAudioChannelLayoutTag_MPEG_5_1_A`
/// give the same stereo from the same source, side and rear surrounds fold
/// alike, and LFE is dropped by both. Keeping FFmpeg's order avoids a channel
/// permutation in the resampler.
enum ChannelLayoutBridge {
    /// The CoreAudio label for each channel of `layout`, in FFmpeg's order,
    /// or nil when the layout has no named channels (an unspecified order)
    /// or carries one the engine has no label for. Nil means "fold in
    /// swresample as before"; it never means "guess".
    static func labels(for layout: UnsafePointer<AVChannelLayout>) -> [AudioChannelLabel]? {
        let count = Int(layout.pointee.nb_channels)
        guard count > 0, layout.pointee.order == AV_CHANNEL_ORDER_NATIVE else { return nil }
        var channels: [AVChannel] = []
        channels.reserveCapacity(count)
        for index in 0 ..< count {
            let channel = av_channel_layout_channel_from_index(layout, UInt32(index))
            guard channel != AV_CHAN_NONE else { return nil }
            channels.append(channel)
        }
        // With both a side and a back pair (7.1), the back pair is the rear
        // surround; with one pair (5.1 in either flavour), it is the surround.
        let hasSidePair = channels.contains(AV_CHAN_SIDE_LEFT) || channels.contains(AV_CHAN_SIDE_RIGHT)
        var labels: [AudioChannelLabel] = []
        labels.reserveCapacity(count)
        for channel in channels {
            guard let label = self.label(for: channel, hasSidePair: hasSidePair) else { return nil }
            labels.append(label)
        }
        return labels
    }

    /// An `AVAudioChannelLayout` carrying `labels` as channel descriptions.
    static func layout(labels: [AudioChannelLabel]) -> AVAudioChannelLayout {
        precondition(!labels.isEmpty, "a channel layout needs at least one channel")
        let descriptionSize = MemoryLayout<AudioChannelDescription>.stride
        let byteCount = MemoryLayout<AudioChannelLayout>.size + (labels.count - 1) * descriptionSize
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioChannelLayout>.alignment
        )
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let acl = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        acl.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        acl.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        acl.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        // `mChannelDescriptions` is declared as one element; the allocation
        // above holds `labels.count` of them contiguously after it.
        withUnsafeMutablePointer(to: &acl.pointee.mChannelDescriptions) { first in
            for (index, label) in labels.enumerated() {
                first[index] = AudioChannelDescription(
                    mChannelLabel: label,
                    mChannelFlags: [],
                    mCoordinates: (0, 0, 0)
                )
            }
        }
        return AVAudioChannelLayout(layout: acl)
    }

    // MARK: - Private

    /// FFmpeg channel to CoreAudio label. A dictionary rather than a switch:
    /// `AVChannel` is an imported C enum, and the table reads as the mapping
    /// it is. The back pair depends on whether a side pair exists, so it is
    /// resolved by the caller's flag.
    private static let fixedLabels: [AVChannel: AudioChannelLabel] = [
        AV_CHAN_FRONT_LEFT: kAudioChannelLabel_Left,
        AV_CHAN_FRONT_RIGHT: kAudioChannelLabel_Right,
        AV_CHAN_FRONT_CENTER: kAudioChannelLabel_Center,
        AV_CHAN_LOW_FREQUENCY: kAudioChannelLabel_LFEScreen,
        AV_CHAN_FRONT_LEFT_OF_CENTER: kAudioChannelLabel_LeftCenter,
        AV_CHAN_FRONT_RIGHT_OF_CENTER: kAudioChannelLabel_RightCenter,
        AV_CHAN_BACK_CENTER: kAudioChannelLabel_CenterSurround,
        AV_CHAN_SIDE_LEFT: kAudioChannelLabel_LeftSurround,
        AV_CHAN_SIDE_RIGHT: kAudioChannelLabel_RightSurround,
        AV_CHAN_TOP_CENTER: kAudioChannelLabel_TopCenterSurround,
        AV_CHAN_TOP_FRONT_LEFT: kAudioChannelLabel_VerticalHeightLeft,
        AV_CHAN_TOP_FRONT_CENTER: kAudioChannelLabel_VerticalHeightCenter,
        AV_CHAN_TOP_FRONT_RIGHT: kAudioChannelLabel_VerticalHeightRight,
        AV_CHAN_TOP_BACK_LEFT: kAudioChannelLabel_TopBackLeft,
        AV_CHAN_TOP_BACK_CENTER: kAudioChannelLabel_TopBackCenter,
        AV_CHAN_TOP_BACK_RIGHT: kAudioChannelLabel_TopBackRight,
        AV_CHAN_LOW_FREQUENCY_2: kAudioChannelLabel_LFE2,
    ]

    private static func label(for channel: AVChannel, hasSidePair: Bool) -> AudioChannelLabel? {
        if channel == AV_CHAN_BACK_LEFT {
            return hasSidePair ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround
        }
        if channel == AV_CHAN_BACK_RIGHT {
            return hasSidePair ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround
        }
        return self.fixedLabels[channel]
    }
}
