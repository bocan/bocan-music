import AppKit
import Persistence
import SwiftUI

// MARK: - HTMLLoader

/// Off-main-actor cache for HTML-to-AttributedString conversion, keyed by episode guid.
actor HTMLLoader {
    static let shared = HTMLLoader()

    // Bump this version when the rendering CSS changes to invalidate cached entries.
    private static let cacheVersion = 2
    private var cache: [String: AttributedString] = [:]

    func clearCache() {
        self.cache.removeAll()
    }

    func attributedString(for item: EpisodeListItem) async -> AttributedString? {
        let guid = item.episode.guid
        if let cached = cache[guid] { return cached }
        guard let html = item.episode.descriptionHTML, !html.isEmpty else { return nil }
        let stripped = html.replacingOccurrences(
            of: "<script[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
        // Inject CSS so WebKit renders at a legible system-font size instead of
        // its 12pt Times default. !important overrides any inline styles in the feed.
        let css = """
        <style>
        body, p, div, span, li, td {
            font-family: -apple-system, sans-serif !important;
            font-size: 14px !important;
            line-height: 1.6 !important;
        }
        h1 { font-size: 17px !important; }
        h2 { font-size: 15px !important; }
        h3 { font-size: 14px !important; }
        a { color: -apple-system-blue; }
        </style>
        """
        guard let data = (css + stripped).data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        // NSAttributedString HTML parsing must run on the main thread on macOS.
        // Convert to AttributedString (Sendable) before crossing the isolation boundary.
        let result: AttributedString? = await MainActor.run {
            guard let nsAttr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
                return nil
            }
            return AttributedString(nsAttr)
        }
        guard let result else { return nil }
        self.cache[guid] = result
        return result
    }
}

// MARK: - ShowNotesView

struct ShowNotesView: View {
    let episode: EpisodeListItem?
    /// The show's people, used as the fallback when the episode declares none.
    var showPersons: [PodcastPerson] = []

    @Environment(\.dismiss) private var dismiss
    @State private var attributedContent: AttributedString?

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
            if !self.effectivePersons.isEmpty {
                PodcastPersonsView(title: L10n.string("In This Episode"), persons: self.effectivePersons)
                    .padding([.horizontal, .top])
                    .padding(.bottom, 4)
                Divider()
            }
            self.contentView
        }
        .task(id: self.episode?.episode.guid) { await self.load() }
    }

    @ViewBuilder
    private var contentView: some View {
        if let episode {
            if let content = attributedContent {
                ScrollView {
                    Text(content)
                        .textSelection(.enabled)
                        .padding()
                }
            } else if episode.episode.descriptionHTML?.isEmpty == false {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
}
