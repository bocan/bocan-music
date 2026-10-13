import Foundation
import Observability
import Persistence

// MARK: - TrackRelinker

/// Gives a file that is new by path the row of a hidden track it is the same
/// file as, so a library moved to a new drive or folder keeps its play
/// counts, ratings, playlist entries and history (#647).
///
/// Two files are the same when their sizes are equal and either:
/// - the name and the modification time are equal too, which is what a copy
///   that keeps its dates gives, and is the evidence the quick scan already
///   trusts for a file that did not move; or
/// - the name or the modification time is equal, and the new file's SHA-256
///   equals the hidden track's stored content hash. This is the only case
///   that reads the whole file.
///
/// Only hidden tracks are candidates. A visible track still has its own file
/// as far as the library knows, so a second copy of it is a second track.
actor TrackRelinker {
    private let trackRepo: TrackRepository
    private let log = AppLogger.make(.library)

    /// The hidden tracks by file size, held for the length of one scan so a
    /// moved library costs one read, not one per file. `nil` outside a scan.
    private var index: [Int64: [HiddenTrackCandidate]]?

    init(trackRepo: TrackRepository) {
        self.trackRepo = trackRepo
    }

    // MARK: - Scan lifetime

    /// Reads the hidden tracks once, for the scan that is about to walk.
    func beginScan() async {
        do {
            let candidates = try await self.trackRepo.hiddenTrackCandidates()
            self.index = Dictionary(grouping: candidates, by: \.fileSize)
        } catch {
            // Without the list, every file falls back to its own lookup.
            self.log.warning("relink.index.failed", ["error": String(reflecting: error)])
            self.index = nil
        }
    }

    /// Drops the list `beginScan` read.
    func endScan() {
        self.index = nil
    }

    // MARK: - Re-link

    /// Re-links a hidden track to `url` when the two are the same file.
    ///
    /// - Returns: The re-linked row, visible again and stored under `url`, or
    ///   `nil` when no hidden track is the same file.
    func relink(url: URL, size: Int64, mtime: Int64) async -> Track? {
        guard size > 0 else { return nil }
        let name = Self.fileName(of: url)
        var newFileHash: String?
        for candidate in await self.rankedCandidates(for: url, size: size) {
            let sameName = Self.fileName(ofStored: candidate.fileURL) == name
            let sameTime = candidate.fileMtime == mtime
            guard sameName || sameTime else { continue }
            if !(sameName && sameTime) {
                // Weaker evidence: the bytes decide.
                guard let stored = candidate.contentHash else { continue }
                if newFileHash == nil {
                    newFileHash = await self.contentHash(of: url)
                }
                guard let newFileHash, newFileHash == stored else { continue }
            }
            if let track = await self.claim(candidate, for: url, mtime: mtime) {
                return track
            }
        }
        return nil
    }

    /// The hidden tracks of `size` bytes, the one whose old path ends most
    /// like `url` first. True duplicates (the same bytes in two folders) then
    /// each go back to the copy in the matching folder.
    private func rankedCandidates(for url: URL, size: Int64) async -> [HiddenTrackCandidate] {
        let candidates: [HiddenTrackCandidate]
        if let index = self.index {
            candidates = index[size] ?? []
        } else {
            do {
                candidates = try await self.trackRepo.hiddenTrackCandidates(fileSize: size)
            } catch {
                self.log.warning("relink.lookup.failed", ["error": String(reflecting: error)])
                return []
            }
        }
        guard candidates.count > 1 else { return candidates }
        let components = url.pathComponents
        return candidates
            .map { (candidate: $0, shared: Self.sharedSuffix(components, Self.pathComponents(ofStored: $0.fileURL))) }
            .sorted { $0.shared != $1.shared ? $0.shared > $1.shared : $0.candidate.id < $1.candidate.id }
            .map(\.candidate)
    }

    /// Points `candidate` at `url`. Returns `nil` when another file took the
    /// row first, or on a database failure, which is logged.
    private func claim(_ candidate: HiddenTrackCandidate, for url: URL, mtime: Int64) async -> Track? {
        // Whatever happens, this row is spent as a candidate for this scan.
        self.index?[candidate.fileSize]?.removeAll { $0.id == candidate.id }
        do {
            guard try await self.trackRepo.relinkHiddenTrack(
                id: candidate.id,
                toFileURL: url.absoluteString,
                pathDisplay: url.path,
                fileMtime: mtime
            ) else { return nil }
            return try await self.trackRepo.fetch(id: candidate.id)
        } catch {
            self.log.warning("relink.failed", ["id": candidate.id, "error": String(reflecting: error)])
            return nil
        }
    }

    /// The SHA-256 of the file, or `nil` when it cannot be read. Not isolated
    /// to the actor, so one large file does not hold up the other imports.
    private nonisolated func contentHash(of url: URL) async -> String? {
        do {
            return try ContentHashService.sha256Hex(ofFileAt: url)
        } catch {
            self.log.warning("relink.hash.failed", [
                "file": url.lastPathComponent,
                "error": String(reflecting: error),
            ])
            return nil
        }
    }

    // MARK: - Path helpers

    private static func fileName(of url: URL) -> String {
        url.lastPathComponent.precomposedStringWithCanonicalMapping
    }

    private static func fileName(ofStored fileURL: String) -> String? {
        URL(string: fileURL).map(self.fileName(of:))
    }

    private static func pathComponents(ofStored fileURL: String) -> [String] {
        URL(string: fileURL)?.pathComponents ?? []
    }

    /// How many trailing path components two paths have in common.
    static func sharedSuffix(_ lhs: [String], _ rhs: [String]) -> Int {
        zip(lhs.reversed(), rhs.reversed()).prefix { $0 == $1 }.count
    }
}
