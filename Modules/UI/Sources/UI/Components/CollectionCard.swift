import AppKit
import SwiftUI

// MARK: - CollectionCardModel

/// UI-layer model for a single collection card (an artist, genre, or composer).
/// Not persisted; built from view-model state plus the cover-path map.
struct CollectionCardModel: Identifiable, Hashable {
    /// Stable identity: the artist DB id as a string, or the genre/composer name.
    let id: String
    let title: String
    let albumCount: Int
    let songCount: Int
    /// Up to four cover-art paths, deterministic order, for the 2×2 mosaic.
    let coverArtPaths: [String]
}

// MARK: - CollectionCard

/// A single card in a collection grid: a 2×2 cover mosaic (or a single cover, or
/// a placeholder symbol tile), the collection name, and an "N albums · M songs"
/// subtitle. Mirrors the album-grid cell metrics.
///
/// The mosaic is composed off-main by ``CoverMosaicGenerator`` and hopped back
/// into `@MainActor` state; the placeholder tile shows until it arrives, and
/// stays when there are no covers to compose.
struct CollectionCard: View {
    let model: CollectionCardModel
    /// SF Symbol shown in the placeholder tile: `music.mic` (artists),
    /// `tag` (genres), `music.quarternote.3` (composers).
    let placeholderSymbol: String
    /// Localized per-section accessibility hint, e.g. "Opens this artist's
    /// albums and songs".
    let accessibilityHint: String

    @State private var mosaic: NSImage?

    /// Designated initialiser. `previewMosaic` seeds the mosaic state directly
    /// so SwiftUI previews and snapshot tests can render a deterministic image
    /// without the async off-main compose step.
    init(
        model: CollectionCardModel,
        placeholderSymbol: String,
        accessibilityHint: String,
        previewMosaic: NSImage? = nil
    ) {
        self.model = model
        self.placeholderSymbol = placeholderSymbol
        self.accessibilityHint = accessibilityHint
        self._mosaic = State(initialValue: previewMosaic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            self.artwork
                .frame(maxWidth: .infinity)

            Text(self.model.title)
                .font(Typography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            Text(self.subtitle)
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.model.title)
        .accessibilityValue(self.accessibilityValue)
        .accessibilityHint(self.accessibilityHint)
        // Keyed on the path list so cell reuse recomputes; the load guards
        // against a stale path list before assigning (see gotchas).
        .task(id: self.model.coverArtPaths) {
            await self.loadMosaic()
        }
    }

    // MARK: - Artwork

    private var artwork: some View {
        Group {
            if let mosaic = self.mosaic {
                Image(nsImage: mosaic)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                self.placeholderTile
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Colourful seeded gradient (with the section symbol), matching the album
    /// grid's no-art fallback so a card without covers still reads as artwork
    /// rather than an empty grey tile.
    private var placeholderTile: some View {
        GradientPlaceholder(seed: self.seed, symbol: self.placeholderSymbol)
            .aspectRatio(1, contentMode: .fit)
    }

    /// Deterministic gradient seed. Artist cards carry a numeric id; genre and
    /// composer cards carry a name, hashed stably so the colour survives
    /// relaunches (`String.hashValue` is randomised per process).
    private var seed: Int {
        if let intID = Int(self.model.id) { return intID }
        var hash = 5381
        for byte in self.model.id.utf8 {
            hash = (hash &* 33) &+ Int(byte)
        }
        return hash
    }

    // MARK: - Copy

    /// "N albums · M songs" for display, joined the way the smart-playlist
    /// subtitle joins its parts.
    private var subtitle: String {
        L10n.string("\(self.albumPart) · \(self.songPart)")
    }

    /// "N albums, M songs" for VoiceOver, matching the artist list-row value.
    private var accessibilityValue: String {
        L10n.string("\(self.albumPart), \(self.songPart)")
    }

    private var albumPart: String {
        L10n.string("\(self.model.albumCount) albums")
    }

    private var songPart: String {
        L10n.string("\(self.model.songCount) songs")
    }

    // MARK: - Mosaic

    private func loadMosaic() async {
        let paths = self.model.coverArtPaths
        guard !paths.isEmpty else {
            self.mosaic = nil
            return
        }
        let img = await CoverMosaicGenerator.shared.mosaic(paths: paths, version: 0)
        // Tolerate cell reuse: the model may have changed while awaiting.
        guard paths == self.model.coverArtPaths else { return }
        self.mosaic = img
    }
}
