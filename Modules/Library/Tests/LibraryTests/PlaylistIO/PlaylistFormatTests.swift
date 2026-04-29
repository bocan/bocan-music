import Foundation
import Testing
@testable import Library

@Suite("PlaylistFormat")
struct PlaylistFormatTests {
    @Test("preferredExtension matches enum case")
    func preferredExtension() {
        #expect(PlaylistFormat.m3u.preferredExtension == "m3u")
        #expect(PlaylistFormat.m3u8.preferredExtension == "m3u8")
        #expect(PlaylistFormat.pls.preferredExtension == "pls")
        #expect(PlaylistFormat.xspf.preferredExtension == "xspf")
        #expect(PlaylistFormat.cue.preferredExtension == "cue")
        #expect(PlaylistFormat.itunesXML.preferredExtension == "xml")
    }

    @Test("isExportable is true only for M3U/PLS/XSPF families")
    func isExportable() {
        #expect(PlaylistFormat.m3u.isExportable)
        #expect(PlaylistFormat.m3u8.isExportable)
        #expect(PlaylistFormat.pls.isExportable)
        #expect(PlaylistFormat.xspf.isExportable)
        #expect(!PlaylistFormat.cue.isExportable)
        #expect(!PlaylistFormat.itunesXML.isExportable)
    }

    @Test("fromExtension is case-insensitive and rejects unknown")
    func fromExtension() {
        #expect(PlaylistFormat.fromExtension("M3U8") == .m3u8)
        #expect(PlaylistFormat.fromExtension("pls") == .pls)
        #expect(PlaylistFormat.fromExtension("XSPF") == .xspf)
        #expect(PlaylistFormat.fromExtension("cue") == .cue)
        #expect(PlaylistFormat.fromExtension("xml") == .itunesXML)
        #expect(PlaylistFormat.fromExtension("txt") == nil)
    }

    @Test("sniff detects #EXTM3U as m3u8")
    func sniffExtM3U() {
        let data = Data("#EXTM3U\n#EXTINF:1,a\nfoo.flac\n".utf8)
        #expect(PlaylistFormat.sniff(data: data) == .m3u8)
    }

    @Test("sniff strips BOM before checking")
    func sniffStripsBOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("#EXTM3U\n".utf8))
        #expect(PlaylistFormat.sniff(data: data) == .m3u8)
    }

    @Test("sniff detects [playlist] header in any case")
    func sniffPLS() {
        #expect(PlaylistFormat.sniff(data: Data("[playlist]\n".utf8)) == .pls)
        #expect(PlaylistFormat.sniff(data: Data("[Playlist]\n".utf8)) == .pls)
        #expect(PlaylistFormat.sniff(data: Data("[PLAYLIST]\n".utf8)) == .pls)
    }

    @Test("sniff detects XSPF by namespace URI")
    func sniffXSPF() {
        let xml = #"<?xml version="1.0"?><playlist xmlns="http://xspf.org/ns/0/"></playlist>"#
        #expect(PlaylistFormat.sniff(data: Data(xml.utf8)) == .xspf)
    }

    @Test("sniff detects iTunes Library plist")
    func sniffITunesXML() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict></dict></plist>
        """
        #expect(PlaylistFormat.sniff(data: Data(xml.utf8)) == .itunesXML)
    }

    @Test("sniff detects CUE sheet by leading keyword")
    func sniffCUE() {
        let cue = "REM GENRE Rock\nFILE \"album.flac\" WAVE\n  TRACK 01 AUDIO\n"
        #expect(PlaylistFormat.sniff(data: Data(cue.utf8)) == .cue)
    }

    @Test("sniff falls back to extension hint when content is ambiguous")
    func sniffFallbackExtension() {
        let data = Data("song.flac\n".utf8)
        #expect(PlaylistFormat.sniff(data: data, fallback: "pls") == .pls)
    }

    @Test("sniff treats bare path lists as m3u when no hint")
    func sniffBareList() {
        let data = Data("/Music/song.flac\n/Music/two.flac\n".utf8)
        #expect(PlaylistFormat.sniff(data: data) == .m3u)
    }

    @Test("sniff returns nil for empty data")
    func sniffEmpty() {
        #expect(PlaylistFormat.sniff(data: Data()) == nil)
    }
}
