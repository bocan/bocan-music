import Foundation
import Observability

// MARK: - FFmpegDecoder open-input options

extension FFmpegDecoder {
    /// The set of protocols FFmpeg may use for a *remote* input, as a
    /// comma-separated `protocol_whitelist` value. Deliberately excludes
    /// `file`, `concat`, `subfile`, `data`, etc. so a server-supplied URL
    /// cannot make the demuxer read local files. Returns `nil` for local
    /// inputs, which must keep FFmpeg's default protocol set (incl. `file`).
    static func allowedRemoteProtocols(isRemote: Bool) -> String? {
        isRemote ? "http,https,tls,tcp,crypto" : nil
    }

    /// `avformat_open_input` options. For remote (HTTP/HTTPS) inputs:
    /// - `protocol_whitelist`: restricts FFmpeg to network protocols so a
    ///   server-supplied URL cannot read local files (see #280).
    /// - `user_agent`: our real UA. FFmpeg defaults to "Lavf/<ver>", which some
    ///   podcast/tracking CDNs (e.g. Podtrac in front of Buzzsprout) reject with a
    ///   403; any normal UA is accepted. Matches the URLSession feed/chapters UA.
    /// - `reconnect*`: resilience for long-lived streams. Without these a transient
    ///   HTTP drop is an unrecoverable I/O error mid-playback; with them FFmpeg
    ///   re-issues a ranged GET from the current offset and resumes inside the same
    ///   decoder. Bounded so a dead URL gives up to the engine's app-level reconnect
    ///   rather than blocking forever. Unknown keys are ignored by `av_dict_set`
    ///   (safe across builds); verified against the linked FFmpeg 8.1.2.
    ///
    /// Local inputs get no options so FFmpeg's default protocol set (incl. `file`)
    /// still works.
    static func openOptions(isHTTP: Bool) -> [String: String] {
        guard isHTTP else { return [:] }
        var options = ["user_agent": UserAgent.string]
        if let allowed = allowedRemoteProtocols(isRemote: true) {
            options["protocol_whitelist"] = allowed
        }
        options["reconnect"] = "1" // reconnect after a disconnect before EOF
        options["reconnect_streamed"] = "1" // also when FFmpeg deems the stream non-seekable
        options["reconnect_on_network_error"] = "1" // and on tcp/tls error during (re)connect
        options["reconnect_delay_max"] = "5" // cap the backoff between attempts at 5s
        options["reconnect_max_retries"] = "3" // then give up so the engine can rebuild the stream
        return options
    }
}
