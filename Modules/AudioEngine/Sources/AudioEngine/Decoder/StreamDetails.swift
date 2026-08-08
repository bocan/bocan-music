import Foundation

// MARK: - StreamDetails

/// Everything the open decoder knows about its source (phase 27-5): measured
/// facts from the demuxer and codec, plus the ICY response headers for
/// network streams. Captured once at open time; a stream reconnect rebuilds
/// the decoder and re-captures.
public struct StreamDetails: Sendable, Equatable {
    /// Demuxer short name, e.g. "mp3", "aac", "ogg", "hls".
    public let container: String?
    /// Codec name, e.g. "mp3", "aac", "opus", "flac".
    public let codec: String?
    /// Codec profile where the codec distinguishes them, e.g. AAC's
    /// "LC" / "HE-AAC" / "HE-AACv2". Nil when the codec has no profiles.
    public let codecProfile: String?
    /// Decoded sample rate in Hz.
    public let sampleRateHz: Int
    /// Source channel count, before the engine's stereo output conversion.
    public let channelCount: Int
    /// Bitrate the source claims (codec parameters, container, or `icy-br`),
    /// in kbps. Claimed, not measured: a lying header stays a lying header.
    public let claimedBitrateKbps: Int?
    /// `icy-name`: the station's advertised name.
    public let icyName: String?
    /// `icy-genre`: free text, wildly inconsistent between stations.
    public let icyGenre: String?
    /// `icy-description`: the station blurb.
    public let icyDescription: String?
    /// `icy-url`: the station homepage.
    public let icyURL: String?
    /// Whether the server interleaves ICY metadata blocks (`icy-metaint`
    /// present): true means the station sends now-playing titles.
    public let supportsIcyMetadata: Bool

    public init(
        container: String?,
        codec: String?,
        codecProfile: String?,
        sampleRateHz: Int,
        channelCount: Int,
        claimedBitrateKbps: Int?,
        icyName: String? = nil,
        icyGenre: String? = nil,
        icyDescription: String? = nil,
        icyURL: String? = nil,
        supportsIcyMetadata: Bool = false
    ) {
        self.container = container
        self.codec = codec
        self.codecProfile = codecProfile
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.claimedBitrateKbps = claimedBitrateKbps
        self.icyName = icyName
        self.icyGenre = icyGenre
        self.icyDescription = icyDescription
        self.icyURL = icyURL
        self.supportsIcyMetadata = supportsIcyMetadata
    }

    /// The codec with its profile when one exists: "aac (HE-AAC)", else "aac".
    public var codecDisplay: String? {
        guard let codec else { return nil }
        guard let codecProfile, !codecProfile.isEmpty else { return codec }
        return "\(codec) (\(codecProfile))"
    }
}

// MARK: - ICY text helpers

/// Parsing helpers for the ICY sidecar data FFmpeg exposes as raw strings.
public extension StreamDetails {
    /// Parses the newline-joined raw header block FFmpeg exposes as
    /// `icy_metadata_headers` into a lowercased-key dictionary. Keys arrive
    /// as sent by the server ("icy-name: X"); values keep their case.
    static func parseIcyHeaders(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            headers[key] = value
        }
        return headers
    }

    /// ICY payloads have no declared charset. In the wild they are UTF-8 or
    /// Latin-1 (and worse); try UTF-8 first, fall back to Latin-1, never fail.
    static func decodeIcyText(_ bytes: [UInt8]) -> String {
        let data = Data(bytes)
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}
