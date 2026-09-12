import Foundation
import Testing
@testable import Library

// MARK: - SwallowedErrorLibraryConventionTests

/// #459: the `try?` audit found Library sites that carried on as if an
/// operation had succeeded (`docs/audits/try-optional-audit.md`, class (c)).
/// Two of them cannot be driven from a test without a database that fails
/// mid-scan or an unwritable cover-art cache, so these pin the fixed shapes in
/// the source instead.
@Suite("Swallowed-error conventions in Library (#459)")
struct SwallowedErrorLibraryConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // LibraryTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/Library/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the scan's conflict lookup reports a failed read instead of reading it as a new file (#481)")
    func conflictLookupReportsFailure() throws {
        let source = try self.source("Sources/Library/ScanCoordinator.swift")
        // Scoped to the import path: the removal sweep's own `try?` is a
        // separate, still-open audit finding, not this one.
        let start = try #require(source.range(of: "private func importOne("))
        let end = try #require(source.range(of: "private static func canonicalPath("))
        let importOne = String(source[start.lowerBound ..< end.lowerBound])

        #expect(!importOne.contains("try? await self.trackRepo.fetchOne"))
        #expect(importOne.contains("existingTrack = try await self.trackRepo.fetchOne(fileURL: url.absoluteString)"))
        #expect(importOne.contains("scan.existing_lookup_failed"))
    }

    @Test("the lyrics service logs a failed lookup instead of reading it as 'no lyrics' (#492)")
    func lyricsLookupsAreLogged() throws {
        let source = try self.source("Sources/Library/Lyrics/LyricsService.swift")
        #expect(!source.contains("try? await trackRepo.fetch("))
        #expect(!source.contains("try? await artistRepo.fetch("))
        #expect(!source.contains("try? await albumRepo.fetch("))
        for event in ["lyrics.trackLookup.failed", "lyrics.artistLookup.failed",
                      "lyrics.albumLookup.failed", "lyrics.root_scope.rootsUnavailable"] {
            #expect(source.contains(event), "missing \(event)")
        }

        let client = try self.source("Sources/Library/Lyrics/LRClibClient.swift")
        #expect(!client.contains("try? JSONDecoder().decode"))
        #expect(client.contains("lrclib.search.decodeFailed"))
        #expect(client.contains("lrclib.get.decodeFailed"))
    }

    @Test("the scanner and the scan coordinator log the writes they used to drop (#492)")
    func scanWritesAreLogged() throws {
        let scanner = try self.source("Sources/Library/LibraryScanner.swift")
        for event in ["library.root.markInaccessibleFailed", "fsevents.start.rootsUnavailable",
                      "fsevents.file_removed.failed", "fsevents.dir_removed.failed"] {
            #expect(scanner.contains(event), "missing \(event)")
        }

        let coordinator = try self.source("Sources/Library/ScanCoordinator.swift")
        for event in ["scan.setting.readFailed", "scan.removal.failed", "scan.pruneOrphans.failed",
                      "scan.conflict.updateFailed", "scan.bookmark.mintFailed"] {
            #expect(coordinator.contains(event), "missing \(event)")
        }
    }

    @Test("the tag editor logs the rows and stamps it could not read (#492)")
    func editorLookupsAreLogged() throws {
        let transaction = try self.source("Sources/Library/Edit/EditTransaction.swift")
        for event in ["edit.albumArt.albumLookupFailed", "edit.perFileScope.bookmarkUnresolvable",
                      "edit.mtimeStamp.failed", "edit.fallbackRow.albumLookupFailed",
                      "edit.root_scope.rootsUnavailable"] {
            #expect(transaction.contains(event), "missing \(event)")
        }

        let service = try self.source("Sources/Library/Edit/MetadataEditService.swift")
        for event in ["edit.editID.lookupFailed", "undo.rowUpdateFailed", "edit.readTracks.lookupFailed",
                      "edit.storedLyrics.lookupFailed", "conflict.clear.mtimeStampFailed"] {
            #expect(service.contains(event), "missing \(event)")
        }
    }

    @Test("playlist import and export, cue markers and the remote resolver log their failures (#492)")
    func playlistPathsAreLogged() throws {
        let resolver = try self.source("Sources/Library/PlaylistIO/TrackResolver.swift")
        #expect(!resolver.contains("try? await self.trackRepo"))
        #expect(resolver.contains("playlist.import.lookupFailed"))

        let export = try self.source("Sources/Library/PlaylistIO/PlaylistExportService.swift")
        #expect(export.contains("playlist.export.lookupFailed"))

        let cue = try self.source("Sources/Library/PlaylistIO/CueMarkerService.swift")
        #expect(cue.contains("cue.markers.lookupFailed"))
        #expect(cue.contains("cue.markers.clearLookupFailed"))

        let remote = try self.source("Sources/Library/PlaylistIO/RemotePlaylistResolver.swift")
        #expect(remote.contains("playlist.remote.parseFailed"))
    }

    @Test("an edit that cannot cache the user's cover art fails rather than reporting success (#481)")
    func albumArtPersistPropagates() throws {
        let source = try self.source("Sources/Library/Edit/EditTransaction.swift")
        #expect(!source.contains("try? await self.coverArtCache.persist("))
        #expect(source.contains("let persisted = try await self.coverArtCache.persist(extracted, source: \"user\")"))
        #expect(source.contains("private func linkAlbumArt(artData: Data, updates: [Track]) async throws {"))
        #expect(source.contains("try await self.linkAlbumArt(artData: artData, updates: updates.map(\\.track))"))
    }
}
