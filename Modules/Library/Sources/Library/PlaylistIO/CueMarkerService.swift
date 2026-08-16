import Foundation
import Observability
import Persistence

// MARK: - CueMarkerService

/// Attaches CUE sheets to indexed tracks as in-track markers (ADR-087).
///
/// The chapters model: music files are always ordinary tracks; a cue changes
/// the player bar for the file it references, nothing else. Both doors — the
/// scanner's automatic per-folder pass and manual Import Playlist — share
/// this one attach path.
///
/// Inertness by construction: a FILE yielding fewer than two markers writes
/// nothing (a one-FILE-per-track manifest cue therefore changes nothing
/// anywhere), a FILE whose audio is missing on disk is skipped with a
/// warning, and a FILE whose audio is not indexed is skipped quietly.
public struct CueMarkerService: Sendable {
    private let trackRepo: TrackRepository
    private let markerRepo: TrackMarkerRepository
    private let log = AppLogger.make(.library)

    public init(trackRepo: TrackRepository, markerRepo: TrackMarkerRepository) {
        self.trackRepo = trackRepo
        self.markerRepo = markerRepo
    }

    /// Attaches every cue in `folder` (non-recursive), deduped so at most
    /// one cue's markers land per audio file: sheets whose FILE targets all
    /// exist win over partial ones, then lexicographic order for
    /// determinism. Returns the number of tracks that received markers.
    @discardableResult
    public func attachMarkers(inFolder folder: URL) async -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let cues = names
            .filter { $0.lowercased().hasSuffix(".cue") }
            .sorted()
            .map { folder.appendingPathComponent($0) }
        guard !cues.isEmpty else { return 0 }

        // Prefer complete sheets: all FILE targets present on disk.
        let ranked = cues.sorted { a, b in
            let aComplete = Self.allTargetsExist(inCueAt: a)
            let bComplete = Self.allTargetsExist(inCueAt: b)
            if aComplete != bComplete { return aComplete }
            return a.lastPathComponent < b.lastPathComponent
        }

        var claimed: Set<Int64> = []
        var touched = 0
        for cue in ranked {
            touched += await self.attachMarkers(fromCueAt: cue, claimed: &claimed)
        }
        return touched
    }

    /// Attaches one cue's markers. `claimed` carries the track ids already
    /// claimed by an earlier (better-ranked) cue in the same pass, so
    /// overlapping sheets can't fight. Returns tracks that received markers.
    @discardableResult
    public func attachMarkers(fromCueAt url: URL, claimed: inout Set<Int64>) async -> Int {
        let sheet: CUESheet
        do {
            let data = try Data(contentsOf: url)
            sheet = try CUESheetReader.parse(data: data, sourceURL: url)
        } catch {
            self.log.warning("cue.markers.unreadable", [
                "cue": url.lastPathComponent,
                "error": String(reflecting: error),
            ])
            return 0
        }

        var touched = 0
        for file in sheet.files {
            guard let audioURL = file.absoluteURL else { continue }
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                self.log.warning("cue.markers.audioMissing", [
                    "cue": url.lastPathComponent,
                    "audio": audioURL.lastPathComponent,
                ])
                continue
            }
            // Inert below two markers: nothing to navigate, nothing to show.
            guard file.tracks.count >= 2 else { continue }
            let canonical = audioURL.absoluteString.precomposedStringWithCanonicalMapping
            guard let track = try? await self.trackRepo.fetchOne(fileURL: canonical),
                  let trackID = track.id else {
                self.log.debug("cue.markers.notIndexed", ["audio": audioURL.lastPathComponent])
                continue
            }
            guard !claimed.contains(trackID) else { continue }

            let markers = file.tracks.map { cueTrack in
                TrackMarker(
                    trackID: trackID,
                    positionMs: cueTrack.startMs,
                    title: cueTrack.title,
                    performer: cueTrack.performer ?? sheet.performer
                )
            }
            do {
                try await self.markerRepo.replaceMarkers(forTrack: trackID, with: markers)
                claimed.insert(trackID)
                touched += 1
                self.log.debug("cue.markers.attached", [
                    "audio": audioURL.lastPathComponent,
                    "markers": markers.count,
                ])
            } catch {
                self.log.warning("cue.markers.writeFailed", [
                    "audio": audioURL.lastPathComponent,
                    "error": String(reflecting: error),
                ])
            }
        }
        return touched
    }

    /// Whether every FILE target of the cue at `url` exists on disk.
    private static func allTargetsExist(inCueAt url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let sheet = try? CUESheetReader.parse(data: data, sourceURL: url) else { return false }
        return sheet.files.allSatisfy { file in
            guard let target = file.absoluteURL else { return false }
            return FileManager.default.fileExists(atPath: target.path)
        }
    }
}
