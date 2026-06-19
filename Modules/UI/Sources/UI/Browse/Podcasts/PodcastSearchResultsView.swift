import SwiftUI

// MARK: - PodcastSearchResultsView

/// Results dropdown shown below the Add bar when `searchState != .idle`.
///
/// Shows: an add-by-URL row (when the text parses as a feed URL), then one of
/// three content states: searching spinner / empty message / results list.
struct PodcastSearchResultsView: View {
    @ObservedObject var vm: PodcastsViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let urlCandidate = self.vm.addByURLCandidate {
                    AddByURLRow(url: urlCandidate) {
                        Task { await self.vm.openDetailForURL(urlCandidate) }
                    }
                    Divider()
                }

                switch self.vm.searchState {
                case .searching:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(localized: "Searching…")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)

                case .empty:
                    ContentUnavailableView(
                        L10n.string("No Podcasts Found"),
                        systemImage: "magnifyingglass",
                        description: Text(localized: "No podcasts found.")
                    )

                case let .error(message):
                    VStack(alignment: .leading, spacing: 12) {
                        Label(
                            L10n.string("Podcast search unavailable."),
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.primary)
                        Text(verbatim: message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(L10n.string("Retry")) {
                            Task { await self.vm.retrySearch() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()

                case .results:
                    ForEach(self.vm.searchResults) { result in
                        PodcastSearchResultRow(result: result) {
                            Task { await self.vm.openDetail(result) }
                        }
                        Divider()
                            .padding(.leading, 64)
                    }

                case .idle:
                    EmptyView()
                }
            }
        }
        .background(.background)
    }
}

// MARK: - AddByURLRow

/// Row shown at the top of results when the add-bar text parses as a feed URL.
private struct AddByURLRow: View {
    let url: URL
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: "Add this feed")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(verbatim: self.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("Add this feed"))
    }
}

// MARK: - PodcastSearchResultRow

/// A single search result row: thumbnail, title + author, source badge.
private struct PodcastSearchResultRow: View {
    let result: UIPodcastSearchResult
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 12) {
                self.thumbnail
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    // Feed content -- not localized.
                    Text(self.result.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let author = self.result.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
                PodcastSourceBadge(sources: self.result.sources)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [self.result.title, self.result.author].compactMap(\.self).joined(separator: ", ")
        )
        .accessibilityHint(L10n.string("Double-tap to open podcast"))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let artURL = self.result.artworkURL {
            AsyncImage(url: artURL) { phase in
                switch phase {
                case let .success(img):
                    img.resizable().scaledToFill()

                default:
                    GradientPlaceholder(seed: self.result.canonicalFeedKey.hashValue)
                }
            }
        } else {
            GradientPlaceholder(seed: self.result.canonicalFeedKey.hashValue)
        }
    }
}

// MARK: - PodcastSourceBadge

/// Small, quiet indicator of which search index(es) a result came from.
///
/// Uses SF Symbols only -- no third-party logos -- and spells out the sources
/// via accessibility label and tooltip for users who need the context.
public struct PodcastSourceBadge: View {
    public let sources: Set<UIPodcastSearchSource>

    public init(sources: Set<UIPodcastSearchSource>) {
        self.sources = sources
    }

    private var accessibilityText: String {
        switch (self.sources.contains(.podcastIndex), self.sources.contains(.itunes)) {
        case (true, true):
            L10n.string("Found on Podcast Index and Apple Podcasts")

        case (true, false):
            L10n.string("Found on Podcast Index")

        case (false, true):
            L10n.string("Found on Apple Podcasts")

        case (false, false):
            ""
        }
    }

    private var tooltip: String {
        switch (self.sources.contains(.podcastIndex), self.sources.contains(.itunes)) {
        case (true, true):
            L10n.string("From Podcast Index and Apple Podcasts")

        case (true, false):
            L10n.string("From Podcast Index")

        case (false, true):
            L10n.string("From Apple Podcasts")

        case (false, false):
            ""
        }
    }

    public var body: some View {
        HStack(spacing: 3) {
            if self.sources.contains(.podcastIndex) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if self.sources.contains(.itunes) {
                Image(systemName: "applelogo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .help(self.tooltip)
        .accessibilityLabel(self.accessibilityText)
    }
}
