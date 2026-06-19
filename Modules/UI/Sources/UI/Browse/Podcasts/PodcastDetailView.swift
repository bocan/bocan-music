import SwiftUI

// MARK: - PodcastDetailView

/// Sheet presented when the user taps a search result or an add-by-URL row.
///
/// Header: artwork, title, author, source badge, Subscribe / Subscribed button.
/// Body: categories, description, recent-episode preview (newest first, max 25).
struct PodcastDetailView: View {
    @ObservedObject var vm: PodcastsViewModel
    let detail: PodcastDetail

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    self.header
                    if !self.detail.categories.isEmpty {
                        self.categoryChips
                    }
                    if let desc = self.detail.description {
                        Text(desc)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                    if !self.detail.episodePreview.isEmpty {
                        self.episodeSection
                    }
                }
                .padding()
            }
            .navigationTitle(L10n.string("Podcast Details"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("Back")) { self.vm.dismissDetail() }
                }
            }
        }
        .frame(minWidth: 780, minHeight: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            self.artworkView
                .frame(width: 100, height: 100)

            VStack(alignment: .leading, spacing: 6) {
                // Feed content -- not localized.
                Text(self.detail.title)
                    .font(.title2.bold())
                    .lineLimit(3)

                if let author = self.detail.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                PodcastSourceBadge(sources: self.detail.sources)
                    .padding(.top, 2)

                HStack(spacing: 10) {
                    self.subscribeButton
                    self.linkButtons
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artworkView: some View {
        if let artURL = self.detail.artworkURL {
            AsyncImage(url: artURL) { phase in
                switch phase {
                case let .success(img):
                    img.resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                default:
                    GradientPlaceholder(seed: self.detail.title.hashValue)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .aspectRatio(1, contentMode: .fit)
        } else {
            GradientPlaceholder(seed: self.detail.title.hashValue)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Subscribe button

    @ViewBuilder
    private var subscribeButton: some View {
        if self.detail.alreadySubscribed {
            Label(L10n.string("Subscribed"), systemImage: "checkmark.circle.fill")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("Subscribed"))
        } else {
            Button {
                Task { await self.vm.subscribe(fromDetail: self.detail) }
            } label: {
                Text(localized: "Subscribe")
                    .font(.callout.bold())
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(L10n.string("Subscribe"))
        }
    }

    // MARK: - Website + Feed links

    @ViewBuilder
    private var linkButtons: some View {
        Divider().frame(height: 20)
        if let website = self.detail.link {
            Link(destination: website) {
                Label(L10n.string("Website"), systemImage: "globe")
                    .font(.callout)
            }
            .help(website.absoluteString)
        }
        Link(destination: self.detail.feedURL) {
            Label(L10n.string("RSS Feed"), systemImage: "dot.radiowaves.up.forward")
                .font(.callout)
        }
        .help(self.detail.feedURL.absoluteString)
    }

    // MARK: - Category chips

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(self.detail.categories, id: \.self) { cat in
                    // Feed content -- not localized.
                    Text(cat)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundStyle(.tint)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Episode preview

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(localized: "Recent Episodes")
                .font(.headline)

            ForEach(Array(self.detail.episodePreview.prefix(10).enumerated()), id: \.element.id) { index, ep in
                PodcastDetailEpisodeRow(episode: ep)
                if index < min(self.detail.episodePreview.count, 10) - 1 {
                    Divider()
                }
            }
        }
    }
}

// MARK: - PodcastDetailEpisodeRow

/// A single episode in the detail view's recent-episodes preview.
private struct PodcastDetailEpisodeRow: View {
    let episode: PodcastDetailEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Feed content -- not localized.
            Text(self.episode.title)
                .font(.callout)
                .lineLimit(2)

            HStack(spacing: 8) {
                if let date = self.episode.publishedAt {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let dur = self.episode.duration, dur > 0 {
                    Text(
                        Duration.seconds(dur)
                            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - PodcastDetailLoadingView

/// Shown in the sheet while `currentDetail` is still being fetched, or when
/// fetching failed and the user needs a retry / back affordance.
struct PodcastDetailLoadingView: View {
    @ObservedObject var vm: PodcastsViewModel

    var body: some View {
        NavigationStack {
            Group {
                if let errorMsg = self.vm.detailError {
                    ContentUnavailableView {
                        Label(
                            L10n.string("Failed to load podcast details."),
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(verbatim: errorMsg)
                    } actions: {
                        Button(L10n.string("Back")) { self.vm.dismissDetail() }
                    }
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(localized: "Loading…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(L10n.string("Podcast Details"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("Back")) { self.vm.dismissDetail() }
                }
            }
        }
        .frame(minWidth: 780, minHeight: 480)
    }
}
