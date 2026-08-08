import Foundation
import Library
import Persistence
import Testing
@testable import UI

// MARK: - RadioViewModelTests

/// Serialized because the URLProtocol stub shares static handler state.
@MainActor
@Suite("RadioViewModel", .serialized)
struct RadioViewModelTests {
    private static let dialM3U = """
    #EXTM3U
    #PLAYLIST:The Liminal Dial

    #EXTINF:-1,SomaFM: Groove Salad (San Francisco, California)
    https://ice1.somafm.com/groovesalad-256-mp3

    #EXTINF:-1,Ambient Sleeping Pill (South Plainfield, New Jersey)
    https://radio.stereoscenic.com/asp-h

    #EXTINF:-1,Kiosk Radio (Brussels, Belgium)
    https://kioskradiobxl.out.airtime.pro/kioskradiobxl_b

    #EXTINF:-1,CKUT 90.3 FM (Montreal, Canada)
    https://delray.ckut.ca:8001/903fm-192-stereo
    """

    private static func makeVM(stubBody: String = "") async throws -> (RadioViewModel, RadioStationRepository) {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)
        let resolver = RemotePlaylistResolver(
            session: .radioStubbed(body: Data(stubBody.utf8), statusCode: 200)
        )
        return (RadioViewModel(repository: repo, resolver: resolver), repo)
    }

    // MARK: - Validation

    @Test("submitAdd rejects a non-http(s) URL and sets the sheet error")
    func submitAddRejectsBadScheme() async throws {
        let (vm, repo) = try await Self.makeVM()

        let outcome = await vm.submitAdd(name: "X", streamURL: "ftp://a.example/stream", homePage: nil)

        #expect(outcome == .invalid)
        #expect(vm.sheetErrorMessage != nil)
        #expect(try await repo.fetchAll().isEmpty)
    }

    @Test("validatedStreamURL accepts http(s) with a host and nothing else")
    func validatedStreamURLShapes() {
        #expect(RadioViewModel.validatedStreamURL("https://live.kboo.fm:8443/high") != nil)
        #expect(RadioViewModel.validatedStreamURL("  https://a.example/x  ") != nil)
        #expect(RadioViewModel.validatedStreamURL("http://a.example/x") != nil)
        #expect(RadioViewModel.validatedStreamURL("ftp://a.example/x") == nil)
        #expect(RadioViewModel.validatedStreamURL("https://") == nil)
        #expect(RadioViewModel.validatedStreamURL("not a url") == nil)
        #expect(RadioViewModel.validatedStreamURL("") == nil)
    }

    // MARK: - Direct add

    @Test("submitAdd saves a direct stream URL, falling back to the host for an empty name")
    func submitAddSavesDirect() async throws {
        let (vm, repo) = try await Self.makeVM()

        let outcome = await vm.submitAdd(
            name: "   ",
            streamURL: "https://ice1.somafm.com/groovesalad-256-mp3",
            homePage: nil
        )

        #expect(outcome == .saved)
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "ice1.somafm.com")
        #expect(all.first?.homePageURL == nil)
    }

    @Test("submitAdd surfaces a duplicate stream URL as a sheet error")
    func submitAddRejectsDuplicate() async throws {
        let (vm, repo) = try await Self.makeVM()

        _ = await vm.submitAdd(name: "A", streamURL: "https://a.example/stream", homePage: nil)
        let outcome = await vm.submitAdd(name: "B", streamURL: "https://a.example/stream", homePage: nil)

        #expect(outcome == .invalid)
        #expect(vm.sheetErrorMessage != nil)
        #expect(try await repo.fetchAll().count == 1)
    }

    // MARK: - Playlist indirection

    @Test("submitAdd resolves a playlist URL into found stations without writing")
    func submitAddResolvesPlaylist() async throws {
        let (vm, repo) = try await Self.makeVM(stubBody: Self.dialM3U)

        let outcome = await vm.submitAdd(
            name: "",
            streamURL: "https://radio.example/dial.m3u",
            homePage: nil
        )

        guard case let .found(stations) = outcome else {
            Issue.record("Expected .found, got \(outcome)")
            return
        }
        #expect(stations.count == 4)
        #expect(stations.first?.name == "SomaFM: Groove Salad (San Francisco, California)")
        #expect(try await repo.fetchAll().isEmpty, "resolution must not write until Add All")
    }

    @Test("submitAdd keeps an HLS playlist URL as the stream itself")
    func submitAddKeepsHLSURL() async throws {
        let hls = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=286000,CODECS="mp4a.40.2"
        playlist_a.m3u8
        """
        let (vm, repo) = try await Self.makeVM(stubBody: hls)
        let pasted = "https://livepeercdn.studio/hls/85c28sa2o8wppm58/index.m3u8"

        let outcome = await vm.submitAdd(name: "The Lot Radio", streamURL: pasted, homePage: nil)

        #expect(outcome == .saved)
        let all = try await repo.fetchAll()
        #expect(all.first?.streamURL == pasted)
        #expect(all.first?.name == "The Lot Radio")
    }

    @Test("addStations inserts every entry once and reports an honest count")
    func addStationsInsertsOnce() async throws {
        let (vm, repo) = try await Self.makeVM()
        let found = [
            RemotePlaylistStation(name: "Groove Salad", streamURL: "https://ice1.somafm.com/groovesalad-256-mp3"),
            RemotePlaylistStation(name: nil, streamURL: "https://radio.stereoscenic.com/asp-h"),
        ]

        let first = await vm.addStations(found)
        let second = await vm.addStations(found)

        #expect(first == 2)
        #expect(second == 0, "re-adding the same dial must be idempotent")
        let all = try await repo.fetchAll()
        #expect(all.count == 2)
        #expect(all.contains { $0.name == "radio.stereoscenic.com" }, "nameless entries fall back to the host")
    }

    // MARK: - Edit / delete

    @Test("updateStation saves edits")
    func updateStationSaves() async throws {
        let (vm, repo) = try await Self.makeVM()
        _ = await vm.submitAdd(name: "Old", streamURL: "https://a.example/stream", homePage: nil)
        let station = try #require(try await repo.fetchAll().first)

        let ok = await vm.updateStation(
            station,
            name: "New Name",
            streamURL: station.streamURL,
            homePage: "https://a.example"
        )

        #expect(ok)
        let updated = try #require(try await repo.fetchOne(streamURL: station.streamURL))
        #expect(updated.name == "New Name")
        #expect(updated.homePageURL == "https://a.example")
    }

    @Test("delete removes the station")
    func deleteRemoves() async throws {
        let (vm, repo) = try await Self.makeVM()
        _ = await vm.submitAdd(name: "A", streamURL: "https://a.example/stream", homePage: nil)
        let station = try #require(try await repo.fetchAll().first)

        await vm.delete(station)

        #expect(try await repo.fetchAll().isEmpty)
    }
}

// MARK: - URLSession stub

/// UI-test copy of the Library tests' stub protocol: the resolver takes a
/// real `URLSession`, so tests swap in one whose protocol answers from memory.
class RadioStubURLProtocol: URLProtocol {
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
    static func radioStubbed(body: Data, statusCode: Int) -> URLSession {
        RadioStubURLProtocol.handler = { request in
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
        config.protocolClasses = [RadioStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
