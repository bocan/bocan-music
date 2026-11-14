import Foundation
import Get
import JellyfinAPI

// MARK: - JellyfinStreamURL

/// Builds the audio stream request: the original file, or a transcode.
///
/// | Preferred format | Request |
/// |---|---|
/// | original | the static stream of the original file |
/// | mp3, aac, opus, flac | a transcode with container, codec and a bitrate cap in bit/s |
///
/// The bitrate cap applies only when a format is chosen. With `original` the
/// file is sent as it is, whatever the cap says, because a cap needs a target
/// codec and the user has not chosen one.
///
/// The stream cache waits for the full download before it signals ready, so a
/// transcode with no `Content-Length` is fine, and seek works on the finished
/// file (root `CLAUDE.md`).
enum JellyfinStreamURL {
    static func request(
        itemID: String,
        format: JellyfinStreamFormat,
        bitrate: JellyfinBitrate,
        deviceID: String
    ) -> Request<Data> {
        var parameters = Paths.GetAudioStreamParameters()
        parameters.deviceID = deviceID
        if let container = format.container, let codec = format.audioCodec {
            parameters.container = container
            parameters.audioCodec = codec
            parameters.audioBitRate = bitrate.bitsPerSecond
        } else {
            parameters.isStatic = true
        }
        return Paths.getAudioStream(itemID: itemID, parameters: parameters)
    }
}
