import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

extension UISnapshotTests {
    // MARK: - CollectionCard + CollectionCardGrid snapshots

    @Suite("CollectionCard Snapshots")
    @MainActor
    struct CollectionCardSnapshotTests {
        private let cardSize = CGSize(width: 180, height: 230)

        /// Distinct tile colours for the mosaic snapshots (re-recorded when the
        /// shared TestImage helper replaced the per-test PNG writer).
        private static let fourTiles: [CGColor] = [
            CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1),
            CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1),
            CGColor(red: 0.2, green: 0.7, blue: 0.35, alpha: 1),
            CGColor(red: 0.95, green: 0.6, blue: 0.15, alpha: 1),
        ]
        private static let oneTile: [CGColor] = [CGColor(red: 0.55, green: 0.3, blue: 0.75, alpha: 1)]

        private func mosaic(_ colors: [CGColor]) async throws -> (NSImage, [String]) {
            let paths = try colors.map { try TestImage.solidPNG(color: $0).path }
            let image = try #require(await CoverMosaicGenerator().mosaic(paths: paths, version: 0))
            return (image, paths)
        }

        private func assertCard(
            _ card: CollectionCard,
            dark: Bool,
            named: String
        ) {
            let view = card
                .padding(Theme.albumGridSpacing)
                .frame(width: self.cardSize.width, height: self.cardSize.height)
                .background(Color.bgPrimary)
                .colorScheme(dark ? .dark : .light)
            assertSnapshot(
                of: host(view, size: self.cardSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: named
            )
        }

        private func card(paths: [String], mosaic: NSImage?) -> CollectionCard {
            CollectionCard(
                model: CollectionCardModel(
                    id: "1",
                    title: "Fleetwood Mac",
                    albumCount: 4,
                    songCount: 52,
                    coverArtPaths: paths
                ),
                placeholderSymbol: "music.mic",
                accessibilityHint: "Opens this artist's albums and songs",
                previewMosaic: mosaic
            )
        }

        @Test("Card with four covers light")
        func fourCoversLight() async throws {
            let (image, paths) = try await self.mosaic(Self.fourTiles)
            self.assertCard(self.card(paths: paths, mosaic: image), dark: false, named: "card-four-light")
        }

        @Test("Card with four covers dark")
        func fourCoversDark() async throws {
            let (image, paths) = try await self.mosaic(Self.fourTiles)
            self.assertCard(self.card(paths: paths, mosaic: image), dark: true, named: "card-four-dark")
        }

        @Test("Card with one cover light")
        func oneCoverLight() async throws {
            let (image, paths) = try await self.mosaic(Self.oneTile)
            self.assertCard(self.card(paths: paths, mosaic: image), dark: false, named: "card-one-light")
        }

        @Test("Card with one cover dark")
        func oneCoverDark() async throws {
            let (image, paths) = try await self.mosaic(Self.oneTile)
            self.assertCard(self.card(paths: paths, mosaic: image), dark: true, named: "card-one-dark")
        }

        @Test("Card placeholder light")
        func placeholderLight() {
            self.assertCard(self.card(paths: [], mosaic: nil), dark: false, named: "card-placeholder-light")
        }

        @Test("Card placeholder dark")
        func placeholderDark() {
            self.assertCard(self.card(paths: [], mosaic: nil), dark: true, named: "card-placeholder-dark")
        }

        // MARK: - Genre / composer cards (placeholder variant)

        private func sectionCard(title: String, symbol: String) -> CollectionCard {
            CollectionCard(
                model: CollectionCardModel(
                    id: title, title: title, albumCount: 3, songCount: 24, coverArtPaths: []
                ),
                placeholderSymbol: symbol,
                accessibilityHint: "Opens this collection's songs"
            )
        }

        @Test("Genre card light")
        func genreCardLight() {
            self.assertCard(self.sectionCard(title: "Jazz", symbol: "tag"), dark: false, named: "card-genre-light")
        }

        @Test("Genre card dark")
        func genreCardDark() {
            self.assertCard(self.sectionCard(title: "Jazz", symbol: "tag"), dark: true, named: "card-genre-dark")
        }

        @Test("Composer card light")
        func composerCardLight() {
            self.assertCard(
                self.sectionCard(title: "J.S. Bach", symbol: "music.quarternote.3"),
                dark: false,
                named: "card-composer-light"
            )
        }

        @Test("Composer card dark")
        func composerCardDark() {
            self.assertCard(
                self.sectionCard(title: "J.S. Bach", symbol: "music.quarternote.3"),
                dark: true,
                named: "card-composer-dark"
            )
        }

        // MARK: - Grid

        @Test("CollectionCardGrid fixed layout light")
        func gridLight() {
            let models = (1 ... 6).map { index in
                CollectionCardModel(
                    id: String(index),
                    title: "Artist \(index)",
                    albumCount: index,
                    songCount: index * 10,
                    coverArtPaths: []
                )
            }
            let size = CGSize(width: 600, height: 500)
            let view = CollectionCardGrid(
                models: models,
                placeholderSymbol: "music.mic",
                cardAccessibilityHint: "Opens this artist's albums and songs",
                onOpen: { _ in },
                contextMenu: { _ in EmptyView() },
                scrollOffset: .constant(0)
            )
            .frame(width: size.width, height: size.height)
            .background(Color.bgPrimary)
            .colorScheme(.light)
            assertSnapshot(
                of: host(view, size: size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "collection-grid-light"
            )
        }
    }
}
