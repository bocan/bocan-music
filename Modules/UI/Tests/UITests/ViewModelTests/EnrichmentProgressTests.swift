import Foundation
import Persistence
import Testing
@testable import UI

@Suite("Enrichment progress in the scan banner (#401)")
@MainActor
struct EnrichmentProgressTests {
    @Test("the view model follows the artist lookup pass from the database")
    func followsStamps() async throws {
        let db = try await Database(location: .inMemory)
        let repo = ArtistRepository(database: db)
        _ = try await repo.findOrCreate(name: "Tagged", musicbrainzID: "mbid-1")
        _ = try await repo.findOrCreate(name: "Bare")
        let vm = LibraryViewModel(database: db, engine: MockTransport())

        try await self.waitUntil { vm.enrichmentProgress == ArtistEnrichmentProgress(fetched: 0, total: 1) }
        #expect(vm.enrichmentProgress?.isComplete == false)

        try await repo.setEnrichment(mbid: "mbid-1", disambiguation: nil, sortName: nil, fetchedAt: 1)
        try await self.waitUntil { vm.enrichmentProgress == ArtistEnrichmentProgress(fetched: 1, total: 1) }
        #expect(vm.enrichmentProgress?.isComplete == true)
    }

    @Test("the banner shows the lookup line only while artists remain")
    func bannerConvention() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        url.appendPathComponent("Sources/UI/Import/ScanBanner.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("let progress = self.vm.enrichmentProgress, !progress.isComplete"))
        #expect(source.contains("Looking up artists on MusicBrainz: \\(fetched) of \\(total)"))
        #expect(source.contains("A11y.ScanBanner.enrichmentProgress"))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met in time")
    }
}

@Suite("Track table context menu conventions")
struct TrackContextMenuConventionTests {
    @Test("ContextMenuTableView lets NSTableView set clickedRow before building the menu")
    func superMenuRunsFirst() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        url.appendPathComponent("Sources/UI/Browse/ContextMenuTableView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let superCall = try #require(source.range(of: "super.menu(for: event)"))
        let provider = try #require(source.range(of: "self.menuProvider?()"))
        #expect(superCall.lowerBound < provider.lowerBound, "clickedRow is only valid after NSTableView.menu(for:) has run")
    }
}
