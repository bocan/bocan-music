import Foundation
import Testing
@testable import Library

@Suite("ITunesLibraryReader")
struct ITunesLibraryReaderTests {
    @Test("Parses minimal iTunes XML")
    func parses() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Tracks</key>
          <dict>
            <key>1234</key>
            <dict>
              <key>Track ID</key><integer>1234</integer>
              <key>Name</key><string>Hey Jude</string>
              <key>Artist</key><string>The Beatles</string>
              <key>Album</key><string>Past Masters</string>
              <key>Total Time</key><integer>431000</integer>
              <key>Location</key><string>file:///Users/me/Music/heyjude.m4a</string>
              <key>Play Count</key><integer>17</integer>
            </dict>
            <key>9999</key>
            <dict>
              <key>Track ID</key><integer>9999</integer>
              <key>Name</key><string>Other</string>
              <key>Location</key><string>file:///Users/me/Music/other.m4a</string>
            </dict>
          </dict>
          <key>Playlists</key>
          <array>
            <dict>
              <key>Name</key><string>Music</string>
              <key>Master</key><true/>
              <key>Playlist Items</key>
              <array>
                <dict><key>Track ID</key><integer>1234</integer></dict>
                <dict><key>Track ID</key><integer>9999</integer></dict>
              </array>
            </dict>
            <dict>
              <key>Name</key><string>Favourites</string>
              <key>Folder</key><false/>
              <key>Playlist Items</key>
              <array>
                <dict><key>Track ID</key><integer>1234</integer></dict>
              </array>
            </dict>
          </array>
        </dict>
        </plist>
        """
        let result = try ITunesLibraryReader.parse(data: Data(xml.utf8))
        #expect(result.tracks.count == 2)
        #expect(result.tracks[1234]?.artist == "The Beatles")
        #expect(result.tracks[1234]?.playCount == 17)
        #expect(result.playlists.count == 2)
        #expect(result.playlists[0].name == "Music")
        #expect(result.playlists[0].isMaster == true)
        #expect(result.playlists[1].name == "Favourites")
        #expect(result.playlists[1].trackIDs == [1234])
    }

    @Test("Throws on bad plist")
    func malformed() {
        let bad = "not a plist at all"
        #expect(throws: PlaylistIOError.self) {
            _ = try ITunesLibraryReader.parse(data: Data(bad.utf8))
        }
    }
}
