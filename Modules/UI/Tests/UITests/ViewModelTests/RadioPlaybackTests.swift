import Foundation
import Persistence
import Playback
import Testing
@testable import UI

@MainActor
@Suite("Radio playback")
struct RadioPlaybackTests {
    @Test("makeInternetRadio keeps the live-stream conventions")
    func factoryConventions() throws {
        let url = try #require(URL(string: "https://ice2.somafm.com/deepspaceone-128-mp3"))
        let item = QueueItem.makeInternetRadio(
            name: "Deep Space One",
            streamURL: url,
            homePage: "https://somafm.com"
        )

        #expect(item.trackID == -1)
        #expect(item.bookmark == nil)
        #expect(item.duration == 0, "duration 0 is what disables the scrubber and scrobbling")
        #expect(item.fileURL == url.absoluteString)
        #expect(item.title == "Deep Space One")
        #expect(item.albumName == "https://somafm.com")
        #expect(item.sourceFormat.codec == "stream")
        #expect(item.playableSource == .internetRadio(streamURL: url))
    }

    @Test("makeInternetRadio tolerates a missing home page")
    func factoryWithoutHomePage() throws {
        let url = try #require(URL(string: "https://a.example/stream"))
        let item = QueueItem.makeInternetRadio(name: "A", streamURL: url, homePage: nil)
        #expect(item.albumName == nil)
        #expect(item.playableSource == .internetRadio(streamURL: url))
    }

    @Test("play(radioStation:) surfaces an error when the engine is unavailable")
    func playWithoutEngineSetsError() async throws {
        let db = try await Database(location: .inMemory)
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let station = RadioStation(
            name: "Deep Space One",
            streamURL: "https://ice2.somafm.com/deepspaceone-128-mp3",
            addedAt: 0
        )

        await vm.play(radioStation: station)

        #expect(vm.playbackErrorMessage != nil)
    }
}
