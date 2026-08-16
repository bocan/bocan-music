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
        var supportsTitles = false
        if isHTTP, let fmtCtx = formatCtx {
            icy = self.readIcyHeaders(fmtCtx: fmtCtx)
            if bitrateKbps == nil, let br = icy["icy-br"].flatMap({ Int($0) }), br > 0 {
                bitrateKbps = br
            }
            supportsTitles = icy["icy-metaint"] != nil || self.hasInterleavedMetadata(fmtCtx: fmtCtx)
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
            supportsIcyMetadata: supportsTitles
        )
    }

    /// Whether the connection demonstrably carries interleaved ICY metadata.
    ///
    /// FFmpeg's http protocol consumes the `icy-metaint` response header
    /// itself (it drives the de-interleaving) and never appends it to
    /// `icy_metadata_headers`, so checking the header block alone is blind
    /// even on stations that send titles. Look for evidence instead: a
    /// metadata packet already captured, or a `StreamTitle` that landed in
    /// the context metadata while `avformat_find_stream_info` was reading
    /// (it typically consumes far more bytes than one metaint interval).
    private static func hasInterleavedMetadata(
        fmtCtx: UnsafeMutablePointer<AVFormatContext>
    ) -> Bool {
        if av_dict_get(fmtCtx.pointee.metadata, "StreamTitle", nil, 0) != nil { return true }
        // Ogg Vorbis/Opus streams carry titles as in-band vorbis comments;
        // a TITLE key in the context metadata after open is the equivalent
        // evidence for that key family (#386).
        if av_dict_get(fmtCtx.pointee.metadata, "title", nil, 0) != nil { return true }
        let searchChildren: Int32 = 1 << 0 // AV_OPT_SEARCH_CHILDREN
        var raw: UnsafeMutablePointer<UInt8>?
        let ret = av_opt_get(UnsafeMutableRawPointer(fmtCtx), "icy_metadata_packet", searchChildren, &raw)
        guard ret >= 0, let raw else { return false }
        defer { av_free(raw) }
        return raw.pointee != 0
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

    // MARK: - Live details

    /// The open-time snapshot upgraded with runtime evidence: once a title
    /// has been observed, `supportsIcyMetadata` reports true regardless of
    /// what open-time probing could see.
    var liveDetails: StreamDetails {
        self.lastEmittedTitle != nil
            ? self.streamDetails.withObservedTitles()
            : self.streamDetails
    }

    // MARK: - Read-loop titles

    /// Consumes a pending metadata-updated event, if any: clears the flag and
    /// forwards a changed now-playing string to `titleUpdates`.
    ///
    /// Two flag homes (#386): ICY updates land on the format context
    /// (`AVFMT_EVENT_FLAG_METADATA_UPDATED`), but the Ogg demuxer publishes
    /// each chain's vorbis comments on the STREAM — `AVStream.event_flags`
    /// plus `AVStream.metadata` — so watching the context alone never sees an
    /// Ogg station's song changes.
    func consumeMetadataUpdate(fmtCtx: UnsafeMutablePointer<AVFormatContext>) {
        var updated = false
        if fmtCtx.pointee.event_flags & metadataUpdatedFlag != 0 {
            fmtCtx.pointee.event_flags &= ~metadataUpdatedFlag
            updated = true
        }
        let stream = fmtCtx.pointee.streams?[Int(self.audioStreamIndex)]
        if let stream, stream.pointee.event_flags & metadataUpdatedFlag != 0 {
            stream.pointee.event_flags &= ~metadataUpdatedFlag
            updated = true
        }
        guard updated else { return }
        self.emitTitleIfChanged(fmtCtx: fmtCtx, stream: stream)
    }

    /// Reads the refreshed metadata dictionary and yields a changed
    /// now-playing string. ICY `StreamTitle` wins; live Ogg Vorbis/Opus
    /// streams carry in-band vorbis comments instead, so fall back to
    /// `ARTIST`/`TITLE` for unbounded remote streams (#386) — never for
    /// bounded sources, so a local chained-Ogg file can't hijack the strip's
    /// title. Empty or repeated values are swallowed.
    private func emitTitleIfChanged(
        fmtCtx: UnsafeMutablePointer<AVFormatContext>,
        stream: UnsafeMutablePointer<AVStream>?
    ) {
        let streamTitle = Self.dictValue(fmtCtx.pointee.metadata, key: "StreamTitle")
        var vorbisTitle: String?
        var vorbisArtist: String?
        if self.isUnboundedRemoteStream {
            // Stream-level metadata first: that is where the Ogg demuxer
            // writes each chain's comments; context-level is the fallback.
            let streamMeta = stream?.pointee.metadata
            vorbisTitle = Self.dictValue(streamMeta, key: "title")
                ?? Self.dictValue(fmtCtx.pointee.metadata, key: "title")
            vorbisArtist = Self.dictValue(streamMeta, key: "artist")
                ?? Self.dictValue(fmtCtx.pointee.metadata, key: "artist")
        }
        guard let composed = StreamDetails.composeNowPlayingTitle(
            streamTitle: streamTitle,
            title: vorbisTitle,
            artist: vorbisArtist
        ), composed != self.lastEmittedTitle else { return }
        self.lastEmittedTitle = composed
        self.log.debug("ffmpeg.icy.title", ["title": composed])
        self.titleContinuation.yield(composed)
    }

    /// A trimmed, charset-tolerant value for `key` (case-insensitive; ICY
    /// declares no charset, vorbis comments are UTF-8 — `decodeIcyText`
    /// covers both). Nil when absent or empty.
    private static func dictValue(_ dict: OpaquePointer?, key: String) -> String? {
        guard let entry = av_dict_get(dict, key, nil, 0),
              let valuePtr = entry.pointee.value else { return nil }
        var bytes: [UInt8] = []
        var cursor = valuePtr
        while cursor.pointee != 0 {
            bytes.append(UInt8(bitPattern: cursor.pointee))
            cursor = cursor.successor()
        }
        let text = StreamDetails.decodeIcyText(bytes).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
