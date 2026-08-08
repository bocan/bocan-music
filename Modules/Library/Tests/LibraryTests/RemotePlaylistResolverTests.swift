import Foundation
import Testing
@testable import Library

// MARK: - RemotePlaylistResolver tests

/// Serialized because the suite's private URLProtocol stub keeps static
/// handler state. The stub is deliberately NOT the shared `URLSession.stubbed`
/// helper: that one has a single global handler, so two `.serialized` suites
/// running in parallel overwrite each other's stubs mid-test.
@Suite("RemotePlaylistResolver", .serialized)
struct RemotePlaylistResolverTests {
    /// Shaped like a real curated dial: negative EXTINF durations, titles
    /// with locations, blank separator lines, an HLS URL as an entry, and
    /// extension-less mount points.
    private static let dialM3U = """
    #EXTM3U
    #PLAYLIST:The Liminal Dial

    #EXTINF:-1,SomaFM: Groove Salad (San Francisco, California)
    https://ice1.somafm.com/groovesalad-256-mp3

    #EXTINF:-1,Ambient Sleeping Pill (South Plainfield, New Jersey)
    https://radio.stereoscenic.com/asp-h

    #EXTINF:-1,The Lot Radio (New York City)
    https://livepeercdn.studio/hls/85c28sa2o8wppm58/index.m3u8

    #EXTINF:-1,Radio Caroline (United Kingdom)
    https://stream.radiocaroline.net/rc128/;stream.mp3
    """

    private static func resolver(body: String, statusCode: Int = 200) -> RemotePlaylistResolver {
        RemotePlaylistResolver(session: .resolverStubbed(
            body: Data(body.utf8),
            statusCode: statusCode
        ))
    }

    private static let playlistURL = URL(string: "https://radio.example/dial.m3u")!

    @Test("an M3U station list resolves to stations with title hints")
    func m3uResolvesToStations() async throws {
        let resolution = try await Self.resolver(body: Self.dialM3U).resolve(Self.playlistURL)

        guard case let .stations(stations) = resolution else {
            Issue.record("Expected .stations, got \(resolution)")
            return
        }
        #expect(stations.count == 4)
        #expect(stations.first?.name == "SomaFM: Groove Salad (San Francisco, California)")
        #expect(stations.first?.streamURL == "https://ice1.somafm.com/groovesalad-256-mp3")
        // An HLS URL that appears as an *entry* stays a station like any other.
        #expect(stations.contains { $0.streamURL.hasSuffix("index.m3u8") })
        // Shoutcast's `/;stream.mp3` suffix must survive untouched.
        #expect(stations.contains { $0.streamURL == "https://stream.radiocaroline.net/rc128/;stream.mp3" })
    }

    @Test("a PLS station list resolves to stations")
    func plsResolvesToStations() async throws {
        let pls = """
        [playlist]
        NumberOfEntries=2
        File1=https://ice1.somafm.com/groovesalad-256-mp3
        Title1=Groove Salad
        File2=https://live.kboo.fm:8443/high
        Title2=KBOO FM
        """
        let url = try #require(URL(string: "https://radio.example/dial.pls"))
        let resolution = try await Self.resolver(body: pls).resolve(url)

        guard case let .stations(stations) = resolution else {
            Issue.record("Expected .stations, got \(resolution)")
            return
        }
        #expect(stations.map(\.streamURL) == [
            "https://ice1.somafm.com/groovesalad-256-mp3",
            "https://live.kboo.fm:8443/high",
        ])
        #expect(stations.map(\.name) == ["Groove Salad", "KBOO FM"])
    }

    @Test("an entry without a title hint yields a nil name, not an empty one")
    func missingTitleHintYieldsNilName() async throws {
        let bare = """
        #EXTM3U
        https://ice1.somafm.com/groovesalad-256-mp3
        """
        let resolution = try await Self.resolver(body: bare).resolve(Self.playlistURL)

        guard case let .stations(stations) = resolution else {
            Issue.record("Expected .stations, got \(resolution)")
            return
        }
        #expect(stations.count == 1)
        #expect(stations.first?.name == nil)
    }

    @Test("an HLS variant ladder resolves to .hlsStream, not an empty station list")
    func hlsResolvesToStream() async throws {
        let hls = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=286000,CODECS="mp4a.40.2"
        playlist_a.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.5"
        playlist_b.m3u8
        """
        let url = try #require(URL(string: "https://livepeercdn.studio/hls/x/index.m3u8"))
        let resolution = try await Self.resolver(body: hls).resolve(url)
        #expect(resolution == .hlsStream)
    }

    @Test("a playlist of local file paths is not a station list")
    func localOnlyPlaylistIsNotAPlaylistOfStations() async throws {
        let local = """
        #EXTM3U
        #EXTINF:180,Some Song
        /Users/chris/Music/song.mp3
        """
        let resolution = try await Self.resolver(body: local).resolve(Self.playlistURL)
        #expect(resolution == .notAPlaylist)
    }

    @Test("a non-playlist body resolves to .notAPlaylist")
    func junkBodyIsNotAPlaylist() async throws {
        let resolution = try await Self.resolver(body: "<html>hello</html>")
            .resolve(#require(URL(string: "https://radio.example/index.m3u")))
        #expect(resolution == .notAPlaylist)
    }

    @Test("a non-2xx response throws")
    func errorStatusThrows() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await Self.resolver(body: "", statusCode: 403).resolve(Self.playlistURL)
        }
    }

    @Test("looksLikePlaylist gates on the path extension, case-insensitively")
    func looksLikePlaylistGating() throws {
        let yes = ["https://a.example/dial.m3u", "https://a.example/d.PLS", "https://a.example/x/index.m3u8"]
        let no = [
            "https://ice1.somafm.com/groovesalad-256-mp3",
            "https://radio.stereoscenic.com/asp-h",
            "https://stream.radiocaroline.net/rc128/;stream.mp3",
            "https://live.kboo.fm:8443/high",
        ]
        for raw in yes {
            #expect(try RemotePlaylistResolver.looksLikePlaylist(#require(URL(string: raw))), "\(raw)")
        }
        for raw in no {
            #expect(try !RemotePlaylistResolver.looksLikePlaylist(#require(URL(string: raw))), "\(raw)")
        }
    }
}

// MARK: - Private URLSession stub

/// Suite-private stub so no other suite can race this one's handler.
class ResolverStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let (data, response) = Self.handler?(self.request) else { return }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLSession {
    static func resolverStubbed(body: Data, statusCode: Int) -> URLSession {
        ResolverStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )
            // swiftlint:disable:next force_unwrapping
            return (body, response!)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResolverStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
