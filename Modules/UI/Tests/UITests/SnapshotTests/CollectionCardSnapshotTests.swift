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

        /// Writes a solid-colour PNG to a unique temp file and returns its path.
        private func writePNG(_ color: NSColor) throws -> String {
            let size = NSSize(width: 100, height: 100)
            let image = NSImage(size: size)
            image.lockFocus()
            color.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("card-\(UUID().uuidString).png")
            try png.write(to: url)
            return url.path
        }

        private func mosaic(_ colors: [NSColor]) async throws -> (NSImage, [String]) {
            let paths = try colors.map { try self.writePNG($0) }
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
            let (image, paths) = try await self.mosaic([.systemRed, .systemBlue, .systemGreen, .systemOrange])
            self.assertCard(self.card(paths: paths, mosaic: image), dark: false, named: "card-four-light")
        }

        @Test("Card with four covers dark")
        func fourCoversDark() async throws {
            let (image, paths) = try await self.mosaic([.systemRed, .systemBlue, .systemGreen, .systemOrange])
            self.assertCard(self.card(paths: paths, mosaic: image), dark: true, named: "card-four-dark")
        }

        @Test("Card with one cover light")
        func oneCoverLight() async throws {
            let (image, paths) = try await self.mosaic([.systemPurple])
            self.assertCard(self.card(paths: paths, mosaic: image), dark: false, named: "card-one-light")
        }

        @Test("Card with one cover dark")
        func oneCoverDark() async throws {
            let (image, paths) = try await self.mosaic([.systemPurple])
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
