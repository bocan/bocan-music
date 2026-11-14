import Foundation
import Testing
@testable import Jellyfin

@Suite("Jellyfin models")
struct JellyfinModelsTests {
    @Test("bitrate parses the stored text and converts to bits per second")
    func bitrate() {
        #expect(JellyfinBitrate(storedValue: "original") == .original)
        #expect(JellyfinBitrate(storedValue: "192") == .kbps(192))
        #expect(JellyfinBitrate(storedValue: "garbage") == .original)
        #expect(JellyfinBitrate(storedValue: "0") == .original)
        #expect(JellyfinBitrate(storedValue: "-64") == .original)
        #expect(JellyfinBitrate.kbps(192).storedValue == "192")
        #expect(JellyfinBitrate.kbps(192).bitsPerSecond == 192_000)
        #expect(JellyfinBitrate.original.bitsPerSecond == nil)
        #expect(JellyfinBitrate.original.storedValue == "original")
    }

    @Test("stream format maps to a container and a codec, and original maps to none")
    func format() {
        #expect(JellyfinStreamFormat.original.container == nil)
        #expect(JellyfinStreamFormat.original.audioCodec == nil)
        for format in JellyfinStreamFormat.allCases where format != .original {
            #expect(format.container == format.rawValue)
            #expect(format.audioCodec == format.rawValue)
        }
    }

    @Test("a server strips trailing slashes from its URL and keeps a path prefix")
    func serverURL() {
        let server = JellyfinServer(name: "n", serverURL: URL(string: "https://jf.example.test/media//") ?? URL(filePath: "/"), userID: "u")
        #expect(server.serverURL.absoluteString == "https://jf.example.test/media")
    }

    @Test("a new server gets its own device id, and two servers never share one")
    func deviceID() {
        let first = JellyfinServer(name: "a", serverURL: URL(filePath: "/"), userID: "u")
        let second = JellyfinServer(name: "b", serverURL: URL(filePath: "/"), userID: "u")
        #expect(!first.deviceID.isEmpty)
        #expect(first.deviceID != second.deviceID)
    }

    @Test("connection status helpers")
    func status() {
        #expect(JellyfinConnectionStatus.online(lastPing: Date()).isOnline)
        #expect(!JellyfinConnectionStatus.unknown.isOnline)
        #expect(JellyfinConnectionStatus.authFailed("x").requiresUserAction)
        #expect(!JellyfinConnectionStatus.unreachable("x").requiresUserAction)
        #expect(JellyfinConnectionStatus.unreachable("down").localizedDescription.contains("down"))
    }

    @Test("a search result knows when it is empty")
    func searchResult() {
        #expect(JellyfinSearchResult().isEmpty)
        #expect(!JellyfinSearchResult(songs: [JellyfinSong(id: "1", title: "t")]).isEmpty)
    }

    @Test("error text never contains a URL or a token")
    func errorText() {
        let errors: [JellyfinError] = [
            .network("the request timed out"), .http(status: 500), .unauthorized, .decoding("shape"),
            .keychain(-25300, "read"), .invalidServerRecord("x"), .unknownServer(UUID()), .noAccessToken,
            .quickConnectDisabled, .quickConnectTimedOut, .invalidServerURL("x"), .invalidURL("stream"),
        ]
        for error in errors {
            let text = (error.errorDescription ?? "") + String(reflecting: error)
            #expect(!text.contains("ApiKey"))
            #expect(!text.contains("api_key"))
            #expect(!text.contains("http://"))
            #expect(!text.contains("https://"))
        }
    }
}
