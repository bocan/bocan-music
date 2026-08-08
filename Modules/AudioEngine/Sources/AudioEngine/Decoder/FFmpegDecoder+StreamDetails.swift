import CFFmpeg
import Foundation

// MARK: - FFmpegDecoder stream details + ICY titles (phase 27-5)

/// `AVFMT_EVENT_FLAG_METADATA_UPDATED` — the demuxer refreshed
/// `AVFormatContext.metadata` (ICY StreamTitle for radio). A C #define the
/// importer drops; the app clears the flag after reading, per the API docs.
private let metadataUpdatedFlag: Int32 = 0x0001

extension FFmpegDecoder {
    // MARK: - Open-time capture

    /// Builds the `StreamDetails` snapshot from the open contexts. Pure reads;
    /// never throws, because missing detail must not sink playback.
    static func captureDetails(
        formatCtx: UnsafeMutablePointer<AVFormatContext>?,
        codecParams: UnsafeMutablePointer<AVCodecParameters>,
        isHTTP: Bool
    ) -> StreamDetails {
        let container = formatCtx?.pointee.iformat.map { String(cString: $0.pointee.name) }
        let codec = String(cString: avcodec_get_name(codecParams.pointee.codec_id))
        let profile = avcodec_profile_name(codecParams.pointee.codec_id, codecParams.pointee.profile)
            .map { String(cString: $0) }

        // Claimed bitrate: codec parameters first, container second, icy-br last.
        var bitrateKbps: Int?
        if codecParams.pointee.bit_rate > 0 {
            bitrateKbps = Int(codecParams.pointee.bit_rate) / 1000
        } else if let fmtBitrate = formatCtx?.pointee.bit_rate, fmtBitrate > 0 {
            bitrateKbps = Int(fmtBitrate) / 1000
        }

        var icy: [String: String] = [:]
        if isHTTP, let fmtCtx = formatCtx {
            icy = self.readIcyHeaders(fmtCtx: fmtCtx)
            if bitrateKbps == nil, let br = icy["icy-br"].flatMap({ Int($0) }), br > 0 {
                bitrateKbps = br
            }
        }

        return StreamDetails(
            container: container,
            codec: codec,
            codecProfile: profile,
            sampleRateHz: Int(codecParams.pointee.sample_rate),
            channelCount: Int(codecParams.pointee.ch_layout.nb_channels),
            claimedBitrateKbps: bitrateKbps,
            icyName: icy["icy-name"],
            icyGenre: icy["icy-genre"],
            icyDescription: icy["icy-description"],
            icyURL: icy["icy-url"],
            supportsIcyMetadata: icy["icy-metaint"] != nil
        )
    }

    /// Reads the `icy_metadata_headers` option FFmpeg's http protocol fills in
    /// (the raw `icy-*` response headers, newline-joined). `AV_OPT_SEARCH_CHILDREN`
    /// is required because the option lives on the protocol context, not the
    /// format context itself.
    private static func readIcyHeaders(
        fmtCtx: UnsafeMutablePointer<AVFormatContext>
    ) -> [String: String] {
        let searchChildren: Int32 = 1 << 0 // AV_OPT_SEARCH_CHILDREN
        var raw: UnsafeMutablePointer<UInt8>?
        let ret = av_opt_get(UnsafeMutableRawPointer(fmtCtx), "icy_metadata_headers", searchChildren, &raw)
        guard ret >= 0, let raw else { return [:] }
        defer { av_free(raw) }
        return StreamDetails.parseIcyHeaders(String(cString: raw))
    }

    // MARK: - Read-loop titles

    /// Consumes a pending metadata-updated event, if any: clears the flag and
    /// forwards a changed `StreamTitle` to `titleUpdates`.
    func consumeMetadataUpdate(fmtCtx: UnsafeMutablePointer<AVFormatContext>) {
        guard fmtCtx.pointee.event_flags & metadataUpdatedFlag != 0 else { return }
        fmtCtx.pointee.event_flags &= ~metadataUpdatedFlag
        self.emitTitleIfChanged(fmtCtx: fmtCtx)
    }

    /// Reads `StreamTitle` from the refreshed metadata dictionary and yields
    /// it when it actually changed. Bytes are decoded UTF-8-first with a
    /// Latin-1 fallback because ICY declares no charset; empty or repeated
    /// titles are swallowed.
    private func emitTitleIfChanged(fmtCtx: UnsafeMutablePointer<AVFormatContext>) {
        guard let entry = av_dict_get(fmtCtx.pointee.metadata, "StreamTitle", nil, 0),
              let valuePtr = entry.pointee.value else { return }
        var bytes: [UInt8] = []
        var cursor = valuePtr
        while cursor.pointee != 0 {
            bytes.append(UInt8(bitPattern: cursor.pointee))
            cursor = cursor.successor()
        }
        let title = StreamDetails.decodeIcyText(bytes).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != self.lastEmittedTitle else { return }
        self.lastEmittedTitle = title
        self.log.debug("ffmpeg.icy.title", ["title": title])
        self.titleContinuation.yield(title)
    }
}
