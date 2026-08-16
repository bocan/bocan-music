import Foundation
import Metadata
import Observability
import Persistence

/// Imports a parsed `PlaylistPayload` into the library, materialising a real
/// playlist row plus track membership for every resolved entry.
///
/// Stream entries (http/https, ADR-078 slice 4) never reach the track resolver:
/// they are partitioned out first and upserted into the radio station catalog,
/// so issue #376's all-stream M3U yields stations instead of an empty playlist.
public actor PlaylistImportService {
    private let resolver: TrackResolver
    private let playlists: PlaylistService
    private let trackRepo: TrackRepository
    private let radioStations: RadioStationRepository
    /// Optional: lets CUE import mint per-file bookmarks for audio living
    /// under a library root (issue #391). Nil keeps the pre-#391 behaviour.
    private let libraryRoots: LibraryRootRepository?
    /// Optional: lets CUE import attach in-track markers (ADR-087). Nil
    /// skips the attach; the resolver playlist still imports.
    private let cueMarkers: CueMarkerService?
    private let log = AppLogger.make(.library)

    public init(
        resolver: TrackResolver,
        playlists: PlaylistService,
        trackRepo: TrackRepository,
        radioStations: RadioStationRepository,
        libraryRoots: LibraryRootRepository? = nil,
        cueMarkers: CueMarkerService? = nil
    ) {
        self.resolver = resolver
        self.playlists = playlists
        self.trackRepo = trackRepo
        self.radioStations = radioStations
        self.libraryRoots = libraryRoots
        self.cueMarkers = cueMarkers
    }

    public struct ImportReport: Sendable {
        /// The created playlist, or nil when the payload held only stream
        /// entries (no empty playlist is materialised for a pure station list).
        public let playlistID: Int64?
        public let payloadName: String
        public let resolution: Resolution
        /// Stream entries newly added to the radio station catalog.
        public let stationsAdded: Int
        /// Stream entries seen in the payload (added or already present).
        public let streamEntryCount: Int

        public init(
            playlistID: Int64?,
            payloadName: String,
            resolution: Resolution,
            stationsAdded: Int = 0,
            streamEntryCount: Int = 0
        ) {
            self.playlistID = playlistID
            self.payloadName = payloadName
            self.resolution = resolution
            self.stationsAdded = stationsAdded
            self.streamEntryCount = streamEntryCount
        }
    }

    /// Imports `payload` as a new manual playlist under `parentID`. Stream
    /// entries become radio stations; a playlist row is only created when the
    /// payload holds at least one non-stream entry.
    public func importPayload(
        _ payload: PlaylistPayload,
        parentID: Int64? = nil,
        tolerance: TimeInterval = 2.0
    ) async throws -> ImportReport {
        let (fileEntries, streamEntries) = Self.partition(payload.entries)
        let stationsAdded = await self.importStations(streamEntries)

        var playlistID: Int64?
        var resolution = Resolution(matches: [], misses: [])
        if !fileEntries.isEmpty {
            let filePayload = PlaylistPayload(name: payload.name, entries: fileEntries)
            resolution = await self.resolver.resolve(filePayload, tolerance: tolerance)
            let playlist = try await self.playlists.create(name: payload.name, parentID: parentID)
            guard let pid = playlist.id else {
                throw PlaylistIOError.lookupFailed(reason: "Created playlist has no id")
            }
            playlistID = pid
            // Add resolved track ids in the order they appeared.
            let orderedIDs = resolution.matches
                .sorted { $0.entryIndex < $1.entryIndex }
                .map(\.trackID)
            if !orderedIDs.isEmpty {
                try await self.playlists.addTracks(orderedIDs, to: pid, at: nil)
            }
        }

        self.log.info(
            "playlist.import",
            [
                "playlist_id": playlistID.map(String.init) ?? "none",
                "name": payload.name,
                "matched": resolution.matches.count,
                "missed": resolution.misses.count,
                "stations_added": stationsAdded,
                "stream_entries": streamEntries.count,
            ]
        )
        return ImportReport(
            playlistID: playlistID,
            payloadName: payload.name,
            resolution: resolution,
            stationsAdded: stationsAdded,
            streamEntryCount: streamEntries.count
        )
    }

    // MARK: - Stream partition (ADR-078 slice 4)

    /// Splits entries into local-file candidates and http(s) stream entries.
    /// The format readers deliberately leave remote URLs out of `absoluteURL`,
    /// so the raw `path` string carries the scheme to test.
    static func partition(
        _ entries: [PlaylistPayload.Entry]
    ) -> (files: [PlaylistPayload.Entry], streams: [PlaylistPayload.Entry]) {
        var files: [PlaylistPayload.Entry] = []
        var streams: [PlaylistPayload.Entry] = []
        for entry in entries {
            if Self.isStreamEntry(entry) {
                streams.append(entry)
            } else {
                files.append(entry)
            }
        }
        return (files, streams)
    }

    static func isStreamEntry(_ entry: PlaylistPayload.Entry) -> Bool {
        guard let url = URL(string: entry.path),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Upserts stream entries into the station catalog. Per-entry failures are
    /// logged and skipped so one bad row cannot sink a whole import; existing
    /// stations (same stream URL) are left untouched and not counted.
    private func importStations(_ streams: [PlaylistPayload.Entry]) async -> Int {
        guard !streams.isEmpty else { return 0 }
        var added = 0
        let now = Int64(Date().timeIntervalSince1970)
        for entry in streams {
            guard let url = URL(string: entry.path) else { continue }
            let station = RadioStation(
                name: Self.stationName(for: entry, url: url),
                streamURL: entry.path,
                addedAt: now
            )
            do {
                if try await self.radioStations.upsert(station) { added += 1 }
            } catch {
                self.log.warning("playlist.import.station.failed", [
                    "url": entry.path,
                    "error": String(reflecting: error),
                ])
            }
        }
        return added
    }

    /// Title hint (`#EXTINF` / `TitleN` / XSPF `<title>`) when present,
    /// otherwise the URL host: import must never write an empty name.
    static func stationName(for entry: PlaylistPayload.Entry, url: URL) -> String {
        let title = entry.titleHint?.trimmingCharacters(in: .whitespaces) ?? ""
        if !title.isEmpty { return title }
        return url.host ?? entry.path
    }

    // MARK: - Format-specific entry points

    public func importFile(at url: URL, parentID: Int64? = nil) async throws -> ImportReport {
        let data = try Data(contentsOf: url)
        let format = PlaylistFormat.sniff(data: data, fallback: url.pathExtension) ??
            PlaylistFormat.fromExtension(url.pathExtension) ?? .m3u
        let payload: PlaylistPayload
        switch format {
        case .m3u, .m3u8: payload = try M3UReader.parse(data: data, sourceURL: url)
        case .pls: payload = try PLSReader.parse(data: data, sourceURL: url)
        case .xspf: payload = try XSPFReader.parse(data: data, sourceURL: url)
        case .cue: return try await self.importCUESheet(data: data, url: url, parentID: parentID)
        case .itunesXML:
            throw PlaylistIOError.unrecognisedFormat(url: url)
        }
        return try await self.importPayload(payload, parentID: parentID)
    }

    // MARK: - Preview (no DB writes)

    /// Parses `url` and runs the resolver without persisting anything.
    /// Returns `(matched, missed, stations)` counts for the import preview
    /// sheet: `stations` is how many entries are http(s) streams (27-4).
    /// Never throws: errors are swallowed and return zeros so the UI
    /// degrades gracefully.
    public func previewFile(at url: URL) async -> (matched: Int, missed: Int, stations: Int) {
        do {
            let data = try Data(contentsOf: url)
            let format = PlaylistFormat.sniff(data: data, fallback: url.pathExtension) ??
                PlaylistFormat.fromExtension(url.pathExtension) ?? .m3u
            switch format {
            case .m3u, .m3u8:
                return try await self.resolvePreview(M3UReader.parse(data: data, sourceURL: url))
            case .pls:
                return try await self.resolvePreview(PLSReader.parse(data: data, sourceURL: url))
            case .xspf:
                return try await self.resolvePreview(XSPFReader.parse(data: data, sourceURL: url))
            case .cue:
                // ADR-087: cue FILE entries resolve against indexed tracks
                // like any playlist; the markers themselves have no preview.
                let cueSheet = try CUESheetReader.parse(data: data, sourceURL: url)
                let entries = cueSheet.files.map {
                    PlaylistPayload.Entry(path: $0.path, absoluteURL: $0.absoluteURL)
                }
                return await self.resolvePreview(PlaylistPayload(name: url.lastPathComponent, entries: entries))
            case .itunesXML:
                // iTunes import is not yet wired; show neutral counts.
                return (matched: 0, missed: 0, stations: 0)
            }
        } catch {
            return (matched: 0, missed: 0, stations: 0)
        }
    }

    private func resolvePreview(_ payload: PlaylistPayload) async -> (matched: Int, missed: Int, stations: Int) {
        let (fileEntries, streamEntries) = Self.partition(payload.entries)
        guard !fileEntries.isEmpty else {
            return (matched: 0, missed: 0, stations: streamEntries.count)
        }
        let filePayload = PlaylistPayload(name: payload.name, entries: fileEntries)
        let resolution = await resolver.resolve(filePayload)
        return (
            matched: resolution.matches.count,
            missed: resolution.misses.count,
            stations: streamEntries.count
        )
    }

    // MARK: - CUE sheet import

    /// The audio files referenced by the CUE sheet at `cueURL` that will stay
    /// unreadable even through a library root's scope — the only case where
    /// the import UI genuinely has to ask the user for folder access (#391).
    /// Root-resident audio never reaches the caller: activating the root's
    /// bookmark scope makes it readable, and the marker attach checks
    /// existence through exactly that access, so no prompt is warranted.
    public func cueAudioNeedingAccess(at cueURL: URL) async -> [URL] {
        let unreadable = CUESheetReader.inaccessibleAudio(inCueAt: cueURL)
        guard !unreadable.isEmpty, let libraryRoots else { return unreadable }
        guard let roots = try? await libraryRoots.fetchAll() else { return unreadable }
        var blocked: [URL] = []
        for ref in unreadable {
            var coveredByRoot = false
            for root in roots where !root.isInaccessible {
                let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                guard ref.path.hasPrefix(prefix) else { continue }
                do {
                    coveredByRoot = try await SecurityScope.withAccess(root.bookmark) { _ in
                        FileManager.default.isReadableFile(atPath: ref.path)
                    }
                } catch {
                    self.log.warning("cue.accessProbe.rootScopeFailed", [
                        "root": root.path,
                        "error": String(reflecting: error),
                    ])
                }
                if coveredByRoot { break }
            }
            if !coveredByRoot { blocked.append(ref) }
        }
        return blocked
    }

    /// Imports a CUE sheet per ADR-087: attach in-track markers to the
    /// indexed tracks its FILE entries reference (the chapters model), then
    /// create an ordinary playlist of the real tracks those entries resolve
    /// to — the same TrackResolver path m3u uses, misses counted
    /// identically. Never creates virtual tracks.
    private func importCUESheet(data: Data, url: URL, parentID: Int64?) async throws -> ImportReport {
        let cueSheet = try CUESheetReader.parse(data: data, sourceURL: url)
        let playlistName = cueSheet.title ?? url.deletingPathExtension().lastPathComponent

        if let cueMarkers {
            var claimed: Set<Int64> = []
            await cueMarkers.attachMarkers(fromCueAt: url, claimed: &claimed)
        }

        let entries = cueSheet.files.map {
            PlaylistPayload.Entry(path: $0.path, absoluteURL: $0.absoluteURL)
        }
        return try await self.importPayload(
            PlaylistPayload(name: playlistName, entries: entries),
            parentID: parentID
        )
    }
}
