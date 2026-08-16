import Foundation
import Metadata
import Observability
import Persistence

/// Imports a parsed `PlaylistPayload` into the library, materialising a real
/// playlist row plus track membership for every resolved entry.
///
/// Stream entries (http/https, phase 27-4) never reach the track resolver:
/// they are partitioned out first and upserted into the radio station catalog,
/// so issue #376's all-stream M3U yields stations instead of an empty playlist.
public actor PlaylistImportService {
    private let resolver: TrackResolver
    private let playlists: PlaylistService
    private let trackRepo: TrackRepository
    private let radioStations: RadioStationRepository
    private let log = AppLogger.make(.library)

    public init(
        resolver: TrackResolver,
        playlists: PlaylistService,
        trackRepo: TrackRepository,
        radioStations: RadioStationRepository
    ) {
        self.resolver = resolver
        self.playlists = playlists
        self.trackRepo = trackRepo
        self.radioStations = radioStations
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

    // MARK: - Stream partition (phase 27-4)

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
                let cueSheet = try CUESheetReader.parse(data: data, sourceURL: url)
                return (matched: cueSheet.files.flatMap(\.tracks).count, missed: 0, stations: 0)
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

    /// The audio file's total length minus `startMs`, in seconds, via a
    /// TagLib read of the file's audio properties. Returns 0 when the probe
    /// fails (file unreadable, no scope); callers treat that as "unknown".
    private func probedRemainder(of audioURL: URL, afterMs startMs: Int64) -> TimeInterval {
        do {
            let total = try SecurityScope.withAccess(audioURL) { scoped in
                try TagReader().read(from: scoped).duration
            }
            return max(0, total - TimeInterval(startMs) / 1000.0)
        } catch {
            self.log.warning("cue.import.durationProbeFailed", [
                "file": audioURL.lastPathComponent,
                "error": String(reflecting: error),
            ])
            return 0
        }
    }

    /// Parse a CUE sheet and materialise each TRACK block as a virtual `Track`
    /// row in the database, then group them into a new playlist.
    private func importCUESheet(data: Data, url: URL, parentID: Int64?) async throws -> ImportReport {
        let cueSheet = try CUESheetReader.parse(data: data, sourceURL: url)
        let playlistName = cueSheet.title ?? url.deletingPathExtension().lastPathComponent

        var virtualTrackIDs: [Int64] = []

        for file in cueSheet.files {
            guard let audioURL = file.absoluteURL else {
                self.log.warning("cue.import.noAudioURL", ["cueFile": url.lastPathComponent, "path": file.path])
                continue
            }
            let sourceURLString = audioURL.absoluteString
            let tracks = file.tracks

            for (index, cueTrack) in tracks.enumerated() {
                let startMs = cueTrack.startMs
                let endMs: Int64? = if let explicit = cueTrack.endMs {
                    explicit
                } else if index + 1 < tracks.count {
                    tracks[index + 1].startMs
                } else {
                    nil // last track — play to EOF
                }

                let duration: TimeInterval = if let endMs {
                    TimeInterval(endMs - startMs) / 1000.0
                } else {
                    // Last track: there is no following INDEX to borrow an end
                    // from, so measure the audio file and take the remainder
                    // past the start offset. A failed probe leaves 0; playback
                    // is unaffected either way (the engine plays to decoder
                    // EOF), this is display metadata only.
                    self.probedRemainder(of: audioURL, afterMs: startMs)
                }

                // Virtual fileURL is unique per CUE track; uses a `?cue=N` suffix
                // so the path component still points at the audio file for scope matching.
                let virtualFileURL = sourceURLString + "?cue=\(cueTrack.number)"

                // Skip if this virtual track was already imported — but heal a
                // zero duration left by imports that predate the EOF-track
                // probe above, so re-importing the sheet fixes the display.
                if var existing = try? await trackRepo.fetchOne(fileURL: virtualFileURL), let id = existing.id {
                    if existing.duration == 0, duration > 0 {
                        existing.duration = duration
                        do {
                            try await self.trackRepo.update(existing)
                        } catch {
                            self.log.warning("cue.import.durationHealFailed", [
                                "track": virtualFileURL,
                                "error": String(reflecting: error),
                            ])
                        }
                    }
                    virtualTrackIDs.append(id)
                    continue
                }

                let now = Int64(Date().timeIntervalSince1970)
                let track = Track(
                    fileURL: virtualFileURL,
                    duration: duration,
                    title: cueTrack.title,
                    trackNumber: cueTrack.number,
                    isrc: cueTrack.isrc,
                    startOffsetMs: startMs,
                    endOffsetMs: endMs,
                    sourceFileURL: sourceURLString,
                    addedAt: now,
                    updatedAt: now
                )
                let id = try await trackRepo.insert(track)
                virtualTrackIDs.append(id)
            }
        }

        let playlist = try await playlists.create(name: playlistName, parentID: parentID)
        guard let pid = playlist.id else {
            throw PlaylistIOError.lookupFailed(reason: "Created CUE playlist has no id")
        }
        if !virtualTrackIDs.isEmpty {
            try await self.playlists.addTracks(virtualTrackIDs, to: pid, at: nil)
        }

        self.log.info("cue.import", [
            "playlistID": pid,
            "name": playlistName,
            "tracks": virtualTrackIDs.count,
        ])

        let resolution = Resolution(
            matches: virtualTrackIDs.enumerated().map { Resolution.Match(entryIndex: $0.offset, trackID: $0.element) },
            misses: []
        )
        return ImportReport(playlistID: pid, payloadName: playlistName, resolution: resolution)
    }
}
