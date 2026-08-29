import AppKit
import Foundation
import Library
import SnapshotTesting
import SwiftUI
import Testing
@testable import Persistence
@testable import UI

extension UISnapshotTests {
    // MARK: - Deep Dive report snapshots (#413)

    @Suite("Deep Dive Snapshots")
    @MainActor
    struct DeepDiveSnapshotTests {
        private let size = CGSize(width: 720, height: 560)

        private func makeService() async throws -> DeepDiveService {
            try await DeepDiveService(database: Database(location: .inMemory))
        }

        private func snapshot(_ view: some View, named name: String) {
            assertSnapshot(
                of: host(view.frame(width: self.size.width, height: self.size.height), size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: name
            )
        }

        /// The report structs expose no memberwise init outside Library; the
        /// fixtures come through Codable, the same path the disk cache uses.
        private func decode<R: Decodable>(_ json: String) throws -> R {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(R.self, from: Data(json.utf8))
        }

        @Test("artist report with a guessed id, members, discography and links")
        func artistReport() async throws {
            let vm = try await DeepDiveArtistViewModel(service: self.makeService(), artistID: 1)
            try vm.show(self.decode("""
            {"artistID":1,"mbid":"b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d","mbidGuessed":true,"name":"The Beatles",
             "sortName":"Beatles, The","type":"Group","country":"GB","activeFrom":"1957-03","activeUntil":"1970-04-10","ended":true,
             "bio":{"extract":"The Beatles were an English rock band formed in Liverpool in 1960.",
                    "pageURL":"https://en.wikipedia.org/wiki/The_Beatles","attribution":"Wikipedia, CC BY-SA 4.0"},
             "members":[{"name":"John Lennon","mbid":"m1","begin":"1957-03","end":"1970-04-10","ended":true,"roles":["guitar",
              "lead vocals"]},
                        {"name":"Pete Best","mbid":"m2","begin":"1960-08","end":"1962-08","ended":true,"roles":["drums"]}],
             "links":[{"type":"discogs","url":"https://www.discogs.com/artist/82730"}],
             "discography":[{"title":"Love Me Do","mbid":"rg1","primaryType":"Single","secondaryTypes":[],"year":1962,"owned":false},
                            {"title":"Abbey Road","mbid":"rg2","primaryType":"Album","secondaryTypes":[],"year":1969,"owned":true}],
             "fetchedAt":1720000000}
            """))
            self.snapshot(DeepDiveArtistView(vm: vm), named: "deepdive-artist")
        }

        @Test("album report with label, pressing and nearby releases")
        func albumReport() async throws {
            let vm = try await DeepDiveAlbumViewModel(service: self.makeService(), albumID: 1)
            try vm.show(self.decode("""
            {"albumID":1,"title":"Abbey Road","artistName":"The Beatles","releaseMBID":"rel-a","releaseGroupMBID":"rg-abbey",
             "releaseChosen":true,"primaryType":"Album","secondaryTypes":[],"date":"1969-09-26","country":"GB",
             "status":"Official","barcode":"077774644624","labels":[{"name":"Apple Records","catalogNumber":"PCS 7088"}],
             "formats":["12\\" Vinyl"],"trackCount":17,"ownedTrackCount":17,
             "coverArtArchiveURL":"https://coverartarchive.org/release/rel-a","musicBrainzURL":"https://musicbrainz.org/release/rel-a",
             "nearby":[{"title":"Yellow Submarine","mbid":"rg-ys","primaryType":"Album","year":1969,"owned":false},
                       {"title":"Let It Be","mbid":"rg-lib","primaryType":"Album","year":1970,"owned":true}],
             "fetchedAt":1720000000}
            """))
            self.snapshot(DeepDiveAlbumView(vm: vm), named: "deepdive-album")
        }

        @Test("track report with works, appearances and an AcoustID link")
        func trackReport() async throws {
            let vm = try await DeepDiveTrackViewModel(service: self.makeService(), trackID: 1)
            try vm.show(self.decode("""
            {"trackID":1,"recordingMBID":"rec-1","title":"Come Together","artistCredit":"The Beatles","length":259000,
             "isrcs":["GBAYE0601690"],"firstReleaseYear":1969,"tags":["rock","pop"],
             "appearances":[{"releaseTitle":"Abbey Road","releaseMBID":"rel-a","year":1969,"country":"GB","status":"Official",
              "primaryType":"Album","secondaryTypes":[]},
                            {"releaseTitle":"1967-1970","releaseMBID":"rel-b","year":1973,"country":"US","status":"Official",
                             "primaryType":"Album","secondaryTypes":["Compilation"]}],
             "works":[{"title":"Come Together","mbid":"w-1","composers":["John Lennon","Paul McCartney"],"lyricists":["John Lennon"],
              "writers":[]}],
             "acoustIDURL":"https://acoustid.org/track/abc","fetchedAt":1720000000}
            """))
            self.snapshot(DeepDiveTrackView(vm: vm), named: "deepdive-track")
        }

        @Test("retry countdown while MusicBrainz asks us to slow down")
        func retrying() {
            self.snapshot(DeepDiveProgressView(retry: (2, 3)), named: "deepdive-retrying")
        }
    }
}
