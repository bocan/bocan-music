import AppKit
import Persistence
import SwiftUI

// MARK: - HTMLLoader

/// Off-main-actor cache for HTML-to-AttributedString conversion, keyed by episode
/// guid. Rendering runs through `SafeHTMLRenderer` (network-free, whitelist-based);
/// the cache just avoids re-parsing the same notes while scrolling.
actor HTMLLoader {
    static let shared = HTMLLoader()

    private var cache: [String: AttributedString] = [:]

    func clearCache() {
        self.cache.removeAll()
    }

    func attributedString(for item: EpisodeListItem) async -> AttributedString? {
        let guid = item.episode.guid
        if let cached = cache[guid] { return cached }
        guard let html = item.episode.descriptionHTML, !html.isEmpty else { return nil }
        let result = SafeHTMLRenderer.render(html)
        guard !result.characters.isEmpty else { return nil }
        self.cache[guid] = result
        return result
    }
}

// MARK: - ShowNotesView

struct ShowNotesView: View {
    let episode: EpisodeListItem?
    /// The show's people, used as the fallback when the episode declares none.
    var showPersons: [PodcastPerson] = []
    /// The show's `podcast:podroll` recommendations + actions. Nil hides the shelf.
    var podrollContext: PodrollContext?
    /// Fetches this episode's chapters on demand. Returns `[]` on failure or when the
    /// episode declares none; `nil` when chapters are not wired in this context.
    var loadChapters: (() async -> [UIChapter])?

    @Environment(\.dismiss) private var dismiss
    @State private var attributedContent: AttributedString?
    @State private var chapters: [UIChapter] = []

    /// The credits to show for this episode: its own people replace the show's when
    /// present, otherwise the show's hosts (Podcasting 2.0 `podcast:person` semantics).
    private var effectivePersons: [PodcastPerson] {
        guard let episode else { return [] }
        return PodcastPerson.effective(episode: episode.episode.persons, show: self.showPersons)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localized: "Show Notes")
                    .font(.headline)
                Spacer()
                // Visible Done button (macOS convention for a read-only sheet);
                // `.cancelAction` keeps Escape working and makes it discoverable.
                Button(L10n.string("Done")) { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top])
            Divider().padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let podrollContext {
                        PodrollShelf(context: podrollContext)
                    }
                    if !self.effectivePersons.isEmpty {
                        PodcastPersonsView(title: L10n.string("In This Episode"), persons: self.effectivePersons)
                    }
                    if !self.chapters.isEmpty {
                        self.chaptersSection
                    }
                    self.notesContent
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: self.episode?.episode.guid) {
            await self.load()
            await self.loadChaptersIfPresent()
        }
    }

    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized: "Chapters")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(self.chapters) { chapter in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: TranscriptView.timestamp(chapter.startTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 56, alignment: .leading)
                    Text(verbatim: chapter.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var notesContent: some View {
        if let episode {
            if let content = attributedContent {
                Text(content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if episode.episode.descriptionHTML?.isEmpty == false {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
            } else if self.chapters.isEmpty {
                ContentUnavailableView(
                    L10n.string("No show notes available."),
                    systemImage: "doc.text"
                )
            }
        } else {
            ContentUnavailableView(
                L10n.string("Select an episode to read its notes."),
                systemImage: "doc.text"
            )
        }
    }

    private func load() async {
        self.attributedContent = nil
        guard let episode else { return }
        self.attributedContent = await HTMLLoader.shared.attributedString(for: episode)
    }

    private func loadChaptersIfPresent() async {
        self.chapters = []
        guard self.episode?.episode.chaptersURL != nil, let loadChapters else { return }
        self.chapters = await loadChapters()
    }
}
