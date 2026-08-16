import Foundation
import Testing
@testable import Library

@Suite("CUESheetReader")
struct CUETests {
    @Test("Parses single-file CUE with multiple tracks")
    func singleFile() throws {
        let body = """
        REM GENRE Rock
        PERFORMER "Various Artists"
        TITLE "Comp"
        FILE "image.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Song A"
            PERFORMER "Artist A"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Song B"
            PERFORMER "Artist B"
            INDEX 01 03:20:00
          TRACK 03 AUDIO
            TITLE "Song C"
            PERFORMER "Artist C"
            INDEX 01 07:45:37
        """
        let sheet = try CUESheetReader.parse(
            data: Data(body.utf8),
            sourceURL: URL(fileURLWithPath: "/Music/comp.cue")
        )
        #expect(sheet.title == "Comp")
        #expect(sheet.performer == "Various Artists")
        #expect(sheet.files.count == 1)
        let file = sheet.files[0]
        #expect(file.path == "image.flac")
        #expect(file.tracks.count == 3)
        #expect(file.tracks[0].startMs == 0)
        #expect(file.tracks[0].title == "Song A")
        #expect(file.tracks[1].startMs == 200_000) // 3:20
        #expect(file.tracks[2].startMs == (7 * 60 + 45) * 1000 + (37 * 1000 / 75))
        // Track 1 ends where track 2 begins.
        #expect(file.tracks[0].endMs == 200_000)
        #expect(file.tracks[1].endMs != nil)
        // Last track has nil end (no fileEndMs supplied).
        #expect(file.tracks[2].endMs == nil)
    }

    @Test("MSF parser")
    func msf() {
        #expect(CUESheetReader.parseMSF("00:00:00") == 0)
        #expect(CUESheetReader.parseMSF("01:00:00") == 60000)
        #expect(CUESheetReader.parseMSF("00:00:75") == 1000)
        #expect(CUESheetReader.parseMSF("garbage") == nil)
    }

    @Test("EAC gaps-appended sheets assign each TRACK to the FILE of its INDEX 01")
    func gapsAppendedManifest() throws {
        // The next track opens under the PREVIOUS file: only its INDEX 00
        // pregap lives there, and its INDEX 01 follows the next FILE line.
        // Each FILE must end up with exactly its own track, or a
        // one-file-per-track manifest grows phantom pregap markers
        // (observed live: markers=2 on real per-track album files).
        let sheet = """
        TITLE "Gaps Appended"
        FILE "01 - One.flac" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 00 03:40:00
        FILE "02 - Two.flac" WAVE
            INDEX 01 00:00:00
          TRACK 03 AUDIO
            TITLE "Three"
            INDEX 00 03:10:00
        FILE "03 - Three.flac" WAVE
            INDEX 01 00:00:00
        """
        let parsed = try CUESheetReader.parse(data: Data(sheet.utf8))
        #expect(parsed.files.count == 3)
        #expect(parsed.files.map(\.tracks.count) == [1, 1, 1])
        #expect(parsed.files[0].tracks.first?.title == "One")
        #expect(parsed.files[1].tracks.first?.title == "Two")
        #expect(parsed.files[1].tracks.first?.startMs == 0)
        #expect(parsed.files[2].tracks.first?.title == "Three")
    }

    @Test("inaccessibleAudio reports unreadable references, stays quiet for readable ones (#391)")
    func accessProbe() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            // Restore permissions so the cleanup can delete the file.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("locked.flac").path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        let cue = dir.appendingPathComponent("album.cue")
        let sheet = """
        FILE "open.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        FILE "locked.flac" WAVE
          TRACK 02 AUDIO
            INDEX 01 00:00:00
        """
        try Data(sheet.utf8).write(to: cue)
        try Data([0x01]).write(to: dir.appendingPathComponent("open.flac"))
        let locked = dir.appendingPathComponent("locked.flac")
        try Data([0x01]).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let inaccessible = CUESheetReader.inaccessibleAudio(inCueAt: cue)
        #expect(inaccessible.map(\.lastPathComponent) == ["locked.flac"])

        // Non-cue files never probe.
        #expect(CUESheetReader.inaccessibleAudio(inCueAt: dir.appendingPathComponent("open.flac")).isEmpty)
    }
}
