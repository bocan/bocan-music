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
}
