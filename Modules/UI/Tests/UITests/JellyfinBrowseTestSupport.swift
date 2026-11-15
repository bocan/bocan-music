import Foundation
import Jellyfin
@testable import UI

// MARK: - Guarded

/// A lock-guarded box, so a test double can be `Sendable` and still record calls.
/// Its lock is never held across a suspension point.
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored
    }

    func update(_ body: (inout Value) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        body(&self.stored)
    }
}

// MARK: - Waiting

/// Polls the main actor every 5 ms until `condition` holds or `timeout` passes,
/// so a background update has landed. Returns whether it held. The ceiling is
/// generous because the full UI suite runs main-actor-heavy snapshot tests that
/// can starve a wait for seconds; a pass still returns at once.
@MainActor
func waitUntil(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            return condition()
        }
    }
    return condition()
}

// MARK: - Builders

func jfSong(_ id: String, title: String? = nil, album: String? = nil, disc: Int? = nil, track: Int? = nil) -> JellyfinSong {
    JellyfinSong(id: id, title: title ?? "Song \(id)", albumTitle: album, trackNumber: track, discNumber: disc)
}

func jfSongs(_ count: Int, prefix: String = "s") -> [JellyfinSong] {
    (0 ..< count).map { jfSong("\(prefix)\($0)") }
}

// MARK: - MemoryCache

/// An in-memory `SubsonicMetadataCaching`, the protocol the Jellyfin view models use.
final class MemoryCache: SubsonicMetadataCaching, @unchecked Sendable {
    private let entries = Guarded<[String: Data]>([:])
    let saves = Guarded<Int>(0)

    private func key(_ server: UUID, _ kind: String, _ id: String) -> String {
        "\(server.uuidString)|\(kind)|\(id)"
    }

    func loadCache(serverID: UUID, entityKind: String, entityID: String) async -> Data? {
        self.entries.value[self.key(serverID, entityKind, entityID)]
    }

    func saveCache(serverID: UUID, entityKind: String, entityID: String, payload: Data) async {
        self.entries.update { $0[self.key(serverID, entityKind, entityID)] = payload }
        self.saves.update { $0 += 1 }
    }

    /// Writes raw bytes, for a test that needs a snapshot that does not decode.
    func put(serverID: UUID, kind: String, id: String, data: Data) {
        self.entries.update { $0[self.key(serverID, kind, id)] = data }
    }
}

// MARK: - StubBrowseSource

/// A scripted `JellyfinBrowseDataSource`. Lists are served as pages by
/// `startIndex` and `limit`, as a real server does, and every call is recorded.
final class StubBrowseSource: JellyfinBrowseDataSource, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? {
            "stub failure"
        }
    }

    var allSongs: [JellyfinSong] = []
    var allAlbums: [JellyfinAlbum] = []
    var allArtists: [JellyfinArtist] = []
    var allGenres: [JellyfinGenre] = []
    var genreSongs: [JellyfinSong] = []
    var playlistContents: [JellyfinSong] = []
    var playlistList: [JellyfinPlaylist] = []
    var albumByID: [String: JellyfinAlbum] = [:]
    var songsByAlbum: [String: [JellyfinSong]] = [:]
    var artistByID: [String: JellyfinArtist] = [:]
    var albumsByArtist: [String: [JellyfinAlbum]] = [:]
    var randomList: [JellyfinSong] = []
    var mostPlayedList: [JellyfinSong] = []
    var starredResult = JellyfinSearchResult()
    var searchResults: [UUID: JellyfinSearchResult] = [:]
    /// Server ids whose search never answers within the test's timeout.
    var slowSearch: Set<UUID> = []
    var failSearch: Set<UUID> = []
    var failure: Failure?
    /// When set, every page request reports this total instead of the list size.
    var reportedTotal: Int?

    let songStarts = Guarded<[Int]>([])
    let albumStarts = Guarded<[Int]>([])
    let randomCalls = Guarded<Int>(0)

    private func page<Element>(_ all: [Element], _ start: Int, _ limit: Int) -> JellyfinPage<Element> {
        let slice = Array(all.dropFirst(start).prefix(limit))
        return JellyfinPage(items: slice, total: self.reportedTotal ?? all.count)
    }

    private func check() throws {
        if let failure = self.failure {
            throw failure
        }
    }

    func songs(serverID: UUID, startIndex: Int, limit: Int) async throws -> JellyfinPage<JellyfinSong> {
        try self.check()
        self.songStarts.update { $0.append(startIndex) }
        return self.page(self.allSongs, startIndex, limit)
    }

    func albums(
        serverID: UUID,
        list: JellyfinAlbumList,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinPage<JellyfinAlbum> {
        try self.check()
        self.albumStarts.update { $0.append(startIndex) }
        return self.page(self.allAlbums, startIndex, limit)
    }

    func artists(serverID: UUID, startIndex: Int, limit: Int) async throws -> JellyfinPage<JellyfinArtist> {
        try self.check()
        return self.page(self.allArtists, startIndex, limit)
    }

    func genres(serverID: UUID, startIndex: Int, limit: Int) async throws -> JellyfinPage<JellyfinGenre> {
        try self.check()
        return self.page(self.allGenres, startIndex, limit)
    }

    func songsByGenre(serverID: UUID, genreID: String, startIndex: Int, limit: Int) async throws -> JellyfinPage<JellyfinSong> {
        try self.check()
        return self.page(self.genreSongs, startIndex, limit)
    }

    func album(serverID: UUID, id: String) async throws -> JellyfinAlbum? {
        try self.check()
        return self.albumByID[id]
    }

    func albumSongs(serverID: UUID, albumID: String) async throws -> [JellyfinSong] {
        try self.check()
        return self.songsByAlbum[albumID] ?? []
    }

    func artist(serverID: UUID, id: String) async throws -> JellyfinArtist? {
        try self.check()
        return self.artistByID[id]
    }

    func artistAlbums(serverID: UUID, artistID: String) async throws -> [JellyfinAlbum] {
        try self.check()
        return self.albumsByArtist[artistID] ?? []
    }

    func randomSongs(serverID: UUID, limit: Int) async throws -> [JellyfinSong] {
        try self.check()
        self.randomCalls.update { $0 += 1 }
        return Array(self.randomList.prefix(limit))
    }

    func mostPlayedSongs(serverID: UUID, limit: Int) async throws -> [JellyfinSong] {
        try self.check()
        return Array(self.mostPlayedList.prefix(limit))
    }

    func starred(serverID: UUID) async throws -> JellyfinSearchResult {
        try self.check()
        return self.starredResult
    }

    func playlists(serverID: UUID) async throws -> [JellyfinPlaylist] {
        try self.check()
        return self.playlistList
    }

    func playlistSongs(serverID: UUID, id: String, startIndex: Int, limit: Int) async throws -> JellyfinPage<JellyfinSong> {
        try self.check()
        return self.page(self.playlistContents, startIndex, limit)
    }

    func search(
        serverID: UUID,
        query: String,
        artistCount: Int,
        albumCount: Int,
        songCount: Int
    ) async throws -> JellyfinSearchResult {
        if self.failSearch.contains(serverID) {
            throw Failure()
        }
        if self.slowSearch.contains(serverID) {
            try await Task.sleep(for: .seconds(30))
        }
        return self.searchResults[serverID] ?? JellyfinSearchResult()
    }
}
