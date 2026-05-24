import Foundation
import Testing
@testable import AudioEngine

// MARK: - Stub transport

private actor StubTransport: HTTPTransport {
    struct Script {
        var chunks: [Data]
        var totalBytes: Int64?
        var failAt: Int?
        var error: Error?

        init(chunks: [Data], totalBytes: Int64? = nil, failAt: Int? = nil, error: Error? = nil) {
            self.chunks = chunks
            self.totalBytes = totalBytes
            self.failAt = failAt
            self.error = error
        }
    }

    private var script: Script
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?
    /// If set, the transport pauses (after each chunk) until the test
    /// calls `releaseChunk()`. Lets the test verify "ready-at-threshold"
    /// vs "complete" semantics deterministically.
    private var gate: AsyncStream<Void>.Continuation?
    private var gateStream: AsyncStream<Void>?

    init(script: Script, gated: Bool = false) {
        self.script = script
        if gated {
            var cont: AsyncStream<Void>.Continuation!
            self.gateStream = AsyncStream { c in cont = c }
            self.gate = cont
        }
    }

    func releaseChunk() {
        self.gate?.yield(())
    }

    func finishGate() {
        self.gate?.finish()
    }

    nonisolated func bytes(for request: URLRequest) async throws -> RemoteTrackBytes {
        await self.recordRequest(request)
        let script = await self.snapshotScript()
        let gateStream = await self.gateStream
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var iterator = gateStream?.makeAsyncIterator()
                for (index, chunk) in script.chunks.enumerated() {
                    if iterator != nil {
                        _ = await iterator?.next()
                    }
                    if let failAt = script.failAt, index == failAt {
                        continuation.finish(throwing: script.error ?? RemoteTrackLoaderError.cancelled)
                        return
                    }
                    continuation.yield(chunk)
                }
                if let failAt = script.failAt, failAt >= script.chunks.count {
                    continuation.finish(throwing: script.error ?? RemoteTrackLoaderError.cancelled)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return RemoteTrackBytes(stream: stream, totalBytes: script.totalBytes)
    }

    private func recordRequest(_ request: URLRequest) {
        self.requestCount += 1
        self.lastRequest = request
    }

    private func snapshotScript() -> Script {
        self.script
    }
}

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("subsonic-stream-cache-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeKey(server: UUID = UUID(), song: String = "tr-1", format: String = "mp3", kbps: Int? = 192) -> SubsonicStreamKey {
    SubsonicStreamKey(serverID: server, songID: song, format: format, bitrateKbps: kbps)
}

private func dummyURL() -> URL {
    URL(string: "https://example.invalid/stream")!
}

// MARK: - Tests

@Suite("SubsonicStreamCache")
struct SubsonicStreamCacheTests {
    // MARK: - Cold fetch reaches ready

    @Test("cold fetch returns URL once threshold bytes are buffered")
    func coldFetchReturnsAfterThreshold() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunk = Data(repeating: 0xAA, count: 1024)
        let chunks = Array(repeating: chunk, count: 200) // 200 KB total
        let transport = StubTransport(script: .init(chunks: chunks, totalBytes: 200 * 1024))
        let loader = RemoteTrackLoader(transport: transport)
        let cache = try SubsonicStreamCache(
            configuration: .init(rootDirectory: dir, budgetBytes: 10 * 1024 * 1024, readyThresholdBytes: 50 * 1024),
            loader: loader
        )

        let key = makeKey()
        let url = try await cache.url(for: key) { dummyURL() }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.path.contains(key.serverID.uuidString))

        // Wait briefly for the rest of the download to finish on the actor.
        try await Task.sleep(nanoseconds: 100_000_000)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        #expect(size == 200 * 1024)
        let count = await transport.requestCount
        #expect(count == 1)
    }

    // MARK: - Short track: under threshold

    @Test("a track smaller than the threshold still becomes ready on EOF")
    func shortTrackBecomesReadyOnEOF() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let small = Data(repeating: 0x01, count: 1000)
        let transport = StubTransport(script: .init(chunks: [small], totalBytes: 1000))
        let loader = RemoteTrackLoader(transport: transport)
        let cache = try SubsonicStreamCache(
            configuration: .init(rootDirectory: dir, readyThresholdBytes: 200 * 1024),
            loader: loader
        )

        let url = try await cache.url(for: makeKey()) { dummyURL() }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        #expect(size == 1000)
    }

    // MARK: - Concurrent waiters share one download

    @Test("two concurrent requests for the same key share a single download")
    func concurrentRequestsShareOneDownload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunk = Data(repeating: 0x42, count: 100_000)
        let chunks = Array(repeating: chunk, count: 4) // 400 KB
        let transport = StubTransport(script: .init(chunks: chunks, totalBytes: 400_000))
        let loader = RemoteTrackLoader(transport: transport)
        let cache = try SubsonicStreamCache(
            configuration: .init(rootDirectory: dir, readyThresholdBytes: 50000),
            loader: loader
        )

        let key = makeKey()
        async let first = cache.url(for: key) { dummyURL() }
        async let second = cache.url(for: key) { dummyURL() }
        let (u1, u2) = try await (first, second)
        #expect(u1 == u2)

        try await Task.sleep(nanoseconds: 50_000_000)
        let count = await transport.requestCount
        #expect(count == 1)
    }

    // MARK: - 401 / 410 error propagation

    @Test("an unauthorized mid-stream error surfaces and clears the entry")
    func unauthorizedErrorPropagates() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunk = Data(repeating: 0x55, count: 4096)
        let transport = StubTransport(script: .init(
            chunks: [chunk, chunk],
            totalBytes: 8192,
            failAt: 1,
            error: RemoteTrackLoaderError.unauthorized
        ))
        let loader = RemoteTrackLoader(transport: transport)
        let cache = try SubsonicStreamCache(
            configuration: .init(rootDirectory: dir, readyThresholdBytes: 200 * 1024),
            loader: loader
        )

        do {
            _ = try await cache.url(for: makeKey()) { dummyURL() }
            Issue.record("expected unauthorized error")
        } catch let error as RemoteTrackLoaderError {
            #expect(error == .unauthorized)
        }
        let count = await cache.entryCount()
        #expect(count == 0)
    }

    // MARK: - urlProvider failure short-circuits without leaving an entry

    @Test("urlProvider failure aborts the fetch and leaves no entry behind")
    func urlProviderFailureClearsEntry() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        struct ProviderFailure: Error {}

        let transport = StubTransport(script: .init(chunks: [], totalBytes: 0))
        let loader = RemoteTrackLoader(transport: transport)
        let cache = try SubsonicStreamCache(
            configuration: .init(rootDirectory: dir),
            loader: loader
        )

        do {
            _ = try await cache.url(for: makeKey()) { throw ProviderFailure() }
            Issue.record("expected ProviderFailure")
        } catch is ProviderFailure {
            // expected
        }
        let count = await cache.entryCount()
        #expect(count == 0)
        let requests = await transport.requestCount
        #expect(requests == 0)
    }

    // MARK: - Eviction respects budget and skips pinned entries

    @Test("eviction respects budget and never drops pinned entries")
    func evictionRespectsBudgetAndPinning() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunk = Data(repeating: 0x77, count: 10000)
        let transport = StubTransport(script: .init(chunks: [chunk], totalBytes: 10000))
        let loader = RemoteTrackLoader(transport: transport)
        // Budget = 25 KB; each entry is 10 KB → after three downloads we
        // sit at 30 KB and need to drop a single entry. With k1 pinned, the
        // LRU candidate is k2, which is exactly what we want the cache to
        // pick.
        let cache = try SubsonicStreamCache(
            configuration: .init(rootDirectory: dir, budgetBytes: 25000, readyThresholdBytes: 1000),
            loader: loader
        )

        let server = UUID()
        let k1 = makeKey(server: server, song: "a")
        let k2 = makeKey(server: server, song: "b")
        let k3 = makeKey(server: server, song: "c")

        _ = try await cache.url(for: k1) { dummyURL() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await cache.pin([k1]) // pin oldest so it survives eviction
        _ = try await cache.url(for: k2) { dummyURL() }
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await cache.url(for: k3) { dummyURL() }
        try await Task.sleep(nanoseconds: 100_000_000)

        let containsPinned = await cache.contains(k1)
        let containsMiddle = await cache.contains(k2)
        let containsNewest = await cache.contains(k3)
        #expect(containsPinned, "pinned entry must survive eviction")
        #expect(containsNewest, "newest entry must remain")
        #expect(!containsMiddle, "least-recently-used unpinned entry should have been evicted")
    }

    // MARK: - purge(serverID:)

    @Test("purge removes all entries and files for a single server")
    func purgeRemovesServerEntries() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunk = Data(repeating: 0x09, count: 4096)
        let transport = StubTransport(script: .init(chunks: [chunk], totalBytes: 4096))
        let loader = RemoteTrackLoader(transport: transport)
        let cache = try SubsonicStreamCache(
            configuration: .init(rootDirectory: dir, readyThresholdBytes: 100),
            loader: loader
        )

        let serverA = UUID()
        let serverB = UUID()
        _ = try await cache.url(for: makeKey(server: serverA, song: "a1")) { dummyURL() }
        _ = try await cache.url(for: makeKey(server: serverB, song: "b1")) { dummyURL() }
        try await Task.sleep(nanoseconds: 50_000_000)

        try await cache.purge(serverID: serverA)

        let countA = await cache.contains(makeKey(server: serverA, song: "a1"))
        let countB = await cache.contains(makeKey(server: serverB, song: "b1"))
        #expect(!countA)
        #expect(countB)

        let dirA = dir.appendingPathComponent(serverA.uuidString)
        #expect(!FileManager.default.fileExists(atPath: dirA.path))
    }

    // MARK: - Cache filename stability

    @Test("cacheFilename is stable and disambiguates bitrates")
    func cacheFilenameStability() {
        let server = UUID()
        let mp3 = SubsonicStreamKey(serverID: server, songID: "abc/def", format: "mp3", bitrateKbps: 192)
        let mp3High = SubsonicStreamKey(serverID: server, songID: "abc/def", format: "mp3", bitrateKbps: 320)
        let flac = SubsonicStreamKey(serverID: server, songID: "abc/def", format: "flac", bitrateKbps: nil)
        #expect(mp3.cacheFilename != mp3High.cacheFilename)
        #expect(mp3.cacheFilename != flac.cacheFilename)
        #expect(mp3.cacheFilename.hasSuffix(".mp3"))
        #expect(flac.cacheFilename.hasSuffix(".flac"))
        // Slashes in the song ID must not leak into the filename.
        #expect(!mp3.cacheFilename.contains("/"))
    }
}
