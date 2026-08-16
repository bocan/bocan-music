import Foundation
import Testing
@testable import Library

@Suite("SidecarArt")
struct SidecarArtTests {
    private func makeDir(files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            try Data([0xFF]).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test("matches recognises sidecar names case-insensitively, rejects others")
    func matching() {
        #expect(SidecarArt.matches(URL(fileURLWithPath: "/m/cover.jpg")))
        #expect(SidecarArt.matches(URL(fileURLWithPath: "/m/Folder.PNG")))
        #expect(SidecarArt.matches(URL(fileURLWithPath: "/m/FRONT.webp")))
        #expect(SidecarArt.matches(URL(fileURLWithPath: "/m/AlbumArt.heic")))
        #expect(!SidecarArt.matches(URL(fileURLWithPath: "/m/cover.txt")))
        #expect(!SidecarArt.matches(URL(fileURLWithPath: "/m/back.jpg")))
        #expect(!SidecarArt.matches(URL(fileURLWithPath: "/m/track.mp3")))
    }

    @Test("findURL honours stem priority and case-insensitivity")
    func priority() throws {
        let dir = try makeDir(files: ["Folder.png", "COVER.JPG", "front.gif", "song.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = SidecarArt.findURL(inDirectory: dir)
        #expect(found?.lastPathComponent == "COVER.JPG", "cover.* must beat folder.* and front.*")
    }

    @Test("findURL returns nil when a folder has no sidecar art")
    func absent() throws {
        let dir = try makeDir(files: ["song.mp3", "notes.txt", "back.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SidecarArt.findURL(inDirectory: dir) == nil)
    }
}
