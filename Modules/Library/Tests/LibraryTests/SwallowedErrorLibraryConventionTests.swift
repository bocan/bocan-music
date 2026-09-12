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

    @Test("an edit that cannot cache the user's cover art fails rather than reporting success (#481)")
    func albumArtPersistPropagates() throws {
        let source = try self.source("Sources/Library/Edit/EditTransaction.swift")
        #expect(!source.contains("try? await self.coverArtCache.persist("))
        #expect(source.contains("let persisted = try await self.coverArtCache.persist(extracted, source: \"user\")"))
        #expect(source.contains("private func linkAlbumArt(artData: Data, updates: [Track]) async throws {"))
        #expect(source.contains("try await self.linkAlbumArt(artData: artData, updates: updates.map(\\.track))"))
    }
}
