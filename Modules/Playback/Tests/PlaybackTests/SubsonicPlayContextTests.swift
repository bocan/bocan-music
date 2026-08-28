import Foundation
import Testing
@testable import Playback

@Suite("QueuePlayer Subsonic scrobble context")
struct SubsonicPlayContextTests {
    private func makeFormat() -> AudioSourceFormat {
        AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "mp3")
    }

    @Test("a Subsonic item's album reaches the scrobble context (#408)")
    func subsonicContextCarriesAlbum() {
        let serverID = UUID()
        let item = QueueItem(
            trackID: -1,
            bookmark: nil,
            fileURL: "",
            duration: 245,
            sourceFormat: self.makeFormat(),
            title: "Blue in Green",
            artistName: "Miles Davis",
            albumName: "Kind of Blue",
            playableSource: .subsonic(serverID: serverID, songID: "song-42")
        )
        let context = QueuePlayer.subsonicPlayContext(for: item)
        #expect(context?.serverID == serverID)
        #expect(context?.songID == "song-42")
        #expect(context?.title == "Blue in Green")
        #expect(context?.artist == "Miles Davis")
        #expect(context?.album == "Kind of Blue")
        #expect(context?.albumArtist == nil)
        #expect(context?.duration == 245)
    }

    @Test("non-Subsonic items produce no Subsonic context")
    func localItemHasNoSubsonicContext() {
        let item = QueueItem(trackID: 1, bookmark: nil, fileURL: "/tmp/a.flac", duration: 1, sourceFormat: self.makeFormat())
        #expect(QueuePlayer.subsonicPlayContext(for: item) == nil)
    }
}
