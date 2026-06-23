import Persistence
import SwiftUI

// MARK: - PodrollPreview

/// A podroll recommendation resolved to display fields. Built by fetching the
/// recommended show's feed detail; nil result means the feed could not be reached.
struct PodrollPreview: Equatable {
    var title: String
    var artworkURL: URL?
}

// MARK: - PodrollContext

/// Everything `ShowNotesView` needs to render and act on the podroll shelf,
/// bundled so the call sites pass one value. Empty `items` hides the shelf.
struct PodrollContext {
    var items: [PodcastPodrollItem]
    /// Resolves a recommended feed URL to its title + artwork (best-effort).
    var resolve: (URL) async -> PodrollPreview?
    /// Invoked when a recommendation is tapped (open it in the discovery flow).
    var onSelect: (URL) -> Void
}

// MARK: - PodrollShelf

/// A horizontal strip of `podcast:podroll` recommendations shown at the top of the
/// show notes. Each card lazily resolves the recommended show's title and artwork.
struct PodrollShelf: View {
    let context: PodrollContext

    var body: some View {
        if !self.context.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(localized: "You Might Also Like")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(self.context.items.enumerated()), id: \.offset) { _, item in
                            PodrollCard(
                                item: item,
                                resolve: self.context.resolve,
                                onSelect: self.context.onSelect
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - PodrollCard

private struct PodrollCard: View {
    let item: PodcastPodrollItem
    let resolve: (URL) async -> PodrollPreview?
    let onSelect: (URL) -> Void

    @State private var preview: PodrollPreview?

    private var url: URL? {
        URL(string: self.item.feedURL)
    }

    /// Resolved title, else the feed's own `title` attribute, else its host.
    private var displayTitle: String {
        self.preview?.title ?? self.item.title ?? self.url?.host ?? self.item.feedURL
    }

    var body: some View {
        Button {
            if let url { self.onSelect(url) }
        } label: {
            self.card
        }
        .buttonStyle(.plain)
        .disabled(self.url == nil)
        .help(self.displayTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.displayTitle)
        .accessibilityHint(L10n.string("Opens show details"))
        .task {
            guard let url, self.preview == nil else { return }
            self.preview = await self.resolve(url)
        }
    }

    private var card: some View {
        VStack(spacing: 4) {
            self.artwork
            Text(verbatim: self.displayTitle)
                .font(.caption)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: 88)
        .contentShape(Rectangle())
    }

    private var artwork: some View {
        Group {
            if let art = preview?.artworkURL {
                AsyncImage(url: art) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    self.placeholder
                }
            } else {
                self.placeholder
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.tertiary)
            )
    }
}
