import Foundation

/// Supported playlist serialisation formats.
public enum PlaylistFormat: String, Sendable, CaseIterable {
    case m3u
    case m3u8
    case pls
    case xspf
    case cue
    case itunesXML

    /// File extension used when writing a payload in this format.
    public var preferredExtension: String {
        switch self {
        case .m3u: "m3u"
        case .m3u8: "m3u8"
        case .pls: "pls"
        case .xspf: "xspf"
        case .cue: "cue"
        case .itunesXML: "xml"
        }
    }

    /// Whether this format can be read by `PlaylistImportService`.
    public var isImportable: Bool {
        true
    }

    /// Whether this format is producible by `PlaylistExportService`.
    public var isExportable: Bool {
        switch self {
        case .m3u, .m3u8, .pls, .xspf: true
        case .cue, .itunesXML: false
        }
    }

    /// Best-effort detection from a file extension.
    public static func fromExtension(_ ext: String) -> PlaylistFormat? {
        switch ext.lowercased() {
        case "m3u": .m3u
        case "m3u8": .m3u8
        case "pls": .pls
        case "xspf": .xspf
        case "cue": .cue
        case "xml": .itunesXML
        default: nil
        }
    }

    /// Sniff a format from a buffer. Looks at the first ~512 bytes.
    public static func sniff(data: Data, fallback ext: String? = nil) -> PlaylistFormat? {
        // Try to read up to the first 512 bytes as UTF-8 (BOM-tolerant) or Latin-1 fallback.
        let head = Self.headSnippet(data: data)
        let trimmed = head.drop { $0 == "\u{FEFF}" || $0.isWhitespace || $0.isNewline }

        if trimmed.hasPrefix("#EXTM3U") { return .m3u8 }
        if trimmed.hasPrefix("[playlist]") || trimmed.hasPrefix("[Playlist]") || trimmed.hasPrefix("[PLAYLIST]") {
            return .pls
        }
        if trimmed.contains("xspf.org/ns/0") || trimmed.contains("<playlist") && trimmed.contains("xspf") {
            return .xspf
        }
        if trimmed.contains("<!DOCTYPE plist") {
            return .itunesXML
        }
        // CUE: typically begins with REM, PERFORMER, TITLE, FILE, or CATALOG.
        if trimmed.hasPrefix("REM ") || trimmed.hasPrefix("PERFORMER ") ||
            trimmed.hasPrefix("TITLE ") || trimmed.hasPrefix("FILE ") ||
            trimmed.hasPrefix("CATALOG ") {
            return .cue
        }
        // Bare path-list .m3u: any non-empty, non-comment line as fallback.
        if let ext, let resolved = Self.fromExtension(ext) {
            return resolved
        }
        // Last-resort: if it has lines and looks ASCII-pathy, call it m3u.
        if !trimmed.isEmpty {
            return .m3u
        }
        return nil
    }

    private static func headSnippet(data: Data) -> Substring {
        let prefix = data.prefix(2048)
        if let s = String(data: prefix, encoding: .utf8) { return Substring(s) }
        if let s = String(data: prefix, encoding: .isoLatin1) { return Substring(s) }
        return Substring("")
    }
}
