import Acoustics
import Foundation
import Testing
@testable import UI

// MARK: - Fixtures

private let abbeyRoad = ReleaseOption(
    id: "release-album",
    title: "Abbey Road",
    date: "1969-09-26",
    year: 1969,
    country: "GB",
    status: "Official",
    albumArtist: "The Beatles",
    albumArtistMBID: "artist-mbid",
    releaseGroupID: "rg-mbid",
    trackNumber: 1,
    discNumber: 1,
    trackTotal: 17,
    mediaFormat: "CD"
)

private let reissue2009 = ReleaseOption(
    id: "release-remaster",
    title: "Abbey Road (2009 Remaster)",
    date: "2009-09-09",
    year: 2009,
    country: "XW",
    status: "Official",
    trackNumber: 1,
    discNumber: 1,
    trackTotal: 17,
    mediaFormat: "CD"
)

private let candidate = IdentificationCandidate(
    id: "acoustid-1",
    score: 0.95,
    mbRecordingID: "recording-mbid",
    title: "Come Together",
    artist: "The Beatles",
    album: "Abbey Road",
    trackNumber: 1,
    discNumber: 1,
    year: 1969,
    genre: "Rock",
    isrcs: ["GBAYE0601696"],
    releases: [abbeyRoad, reissue2009]
)

// MARK: - Build-patch tests

@Suite("Identify buildPatch with releases")
@MainActor
struct IdentifyBuildPatchTests {
    @Test("Release-scoped fields and MBIDs follow the selected release")
    func selectedReleaseDrivesPatch() {
        let fields: Set<IdentifyTagField> = [
            .album, .year, .trackTotal, .isrc,
            .mbRecordingID, .mbReleaseID, .mbReleaseGroupID, .mbAlbumArtistID,
        ]
        let patch = IdentifyTrackViewModel.buildPatch(
            candidate: candidate,
            release: abbeyRoad,
            fields: fields
        )
        #expect(patch.album == .some("Abbey Road"))
        #expect(patch.year == .some(1969))
        #expect(patch.trackTotal == .some(17))
        #expect(patch.isrc == .some("GBAYE0601696"))
        #expect(patch.musicbrainzRecordingID == .some("recording-mbid"))
        #expect(patch.musicbrainzReleaseID == .some("release-album"))
        #expect(patch.musicbrainzReleaseGroupID == .some("rg-mbid"))
        #expect(patch.musicbrainzAlbumArtistID == .some("artist-mbid"))
    }

    @Test("Choosing the 2009 reissue changes the release-scoped values")
    func reissueChangesPatch() {
        let patch = IdentifyTrackViewModel.buildPatch(
            candidate: candidate,
            release: reissue2009,
            fields: [.album, .year, .mbReleaseID]
        )
        #expect(patch.album == .some("Abbey Road (2009 Remaster)"))
        #expect(patch.year == .some(2009))
        #expect(patch.musicbrainzReleaseID == .some("release-remaster"))
    }

    @Test("Without a release the candidate's top-level values apply and no release MBIDs are written")
    func noReleaseFallsBack() {
        let patch = IdentifyTrackViewModel.buildPatch(
            candidate: candidate,
            release: nil,
            fields: [.album, .year, .mbReleaseID, .mbReleaseGroupID, .trackTotal]
        )
        #expect(patch.album == .some("Abbey Road"))
        #expect(patch.year == .some(1969))
        #expect(patch.musicbrainzReleaseID == nil)
        #expect(patch.musicbrainzReleaseGroupID == nil)
        #expect(patch.trackTotal == nil)
    }

    @Test("Unselected fields never reach the patch")
    func unselectedFieldsOmitted() {
        let patch = IdentifyTrackViewModel.buildPatch(
            candidate: candidate,
            release: abbeyRoad,
            fields: [.title]
        )
        #expect(patch.title == .some("Come Together"))
        #expect(patch.album == nil)
        #expect(patch.isrc == nil)
        #expect(patch.musicbrainzRecordingID == nil)
    }
}

// MARK: - Resolver default-tick tests

@Suite("IdentifyFieldResolver defaults")
struct IdentifyFieldResolverTests {
    @Test("Advanced fields default ticked only when the current value is empty")
    func advancedTickRule() {
        // No current identifiers: every offered advanced field is a safe add.
        let empty = IdentifyFieldResolver(
            candidate: candidate,
            release: abbeyRoad,
            currentValues: CurrentTagValues()
        ).defaultSelection()
        #expect(empty.contains(.isrc))
        #expect(empty.contains(.mbRecordingID))
        #expect(empty.contains(.mbReleaseID))

        // A differing existing ISRC usually means the file was tagged against a
        // different release on purpose — never default-overwrite it.
        let tagged = IdentifyFieldResolver(
            candidate: candidate,
            release: abbeyRoad,
            currentValues: CurrentTagValues(isrc: "USUM71703861")
        ).defaultSelection()
        #expect(!tagged.contains(.isrc))
    }

    @Test("Primary fields default ticked when the proposal differs")
    func primaryTickRule() {
        let selection = IdentifyFieldResolver(
            candidate: candidate,
            release: abbeyRoad,
            currentValues: CurrentTagValues(title: "Come Together", year: 1968)
        ).defaultSelection()
        #expect(!selection.contains(.title)) // identical — nothing to change
        #expect(selection.contains(.year)) // differs — pre-ticked
    }

    @Test("Fields the candidate cannot offer are never available")
    func unavailableFieldsHidden() {
        let resolver = IdentifyFieldResolver(
            candidate: candidate,
            release: abbeyRoad,
            currentValues: CurrentTagValues()
        )
        // discTotal is unknowable from recording lookups (media is filtered to
        // the matching disc), so it must not surface as a selectable row.
        #expect(!resolver.availableFields(tier: .advanced).contains(.discTotal))
        #expect(resolver.availableFields(tier: .advanced).contains(.isrc))
    }
}

// MARK: - Source conventions

@Suite("Identify metadata depth source conventions")
struct IdentifyMetadataDepthConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Release picker popover exists and uses a popover presentation")
    func releasePickerUsesPopover() throws {
        let source = try self.source("Sources/UI/Fingerprint/ReleasePickerPopover.swift")
        #expect(source.contains(".popover(isPresented:"))
        #expect(source.contains("chevron.up.chevron.down"))
    }

    @Test("Sheet forwards the selected release into the apply path")
    func sheetForwardsRelease() throws {
        let source = try self.source("Sources/UI/Fingerprint/IdentifyTrackSheet.swift")
        #expect(source.contains("release: release"))
    }

    @Test("Selecting a release recomputes the default field selection")
    func releaseChangeRecomputesDefaults() throws {
        let source = try self.source("Sources/UI/Fingerprint/CandidatePickerView.swift")
        #expect(source.contains("onSelectRelease"))
        #expect(source.contains(").defaultSelection()"))
    }

    @Test("Advanced fields sit behind a collapsed-by-default disclosure")
    func advancedDisclosureCollapsed() throws {
        let source = try self.source("Sources/UI/Fingerprint/FieldSelectionGrid.swift")
        #expect(source.contains("initiallyShowAdvanced: Bool = false"))
        #expect(source.contains("Show advanced fields"))
    }
}
