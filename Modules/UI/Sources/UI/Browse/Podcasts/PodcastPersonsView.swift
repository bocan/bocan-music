import AppKit
import Persistence
import SwiftUI

// MARK: - PodcastPersonsView

/// A horizontal credits strip for Podcasting 2.0 `podcast:person` entries: a small
/// avatar, the person's name, and their role. Used on the podcast show page, the
/// pre-subscribe detail, and the episode show-notes sheet. Renders nothing when the
/// list is empty.
///
/// Names and roles are feed content (the role is an open Podcast Taxonomy vocabulary),
/// so they are shown verbatim; only the section `title` is localized by the caller.
struct PodcastPersonsView: View {
    /// Already-localized section heading (e.g. "Hosts", "In This Episode").
    let title: String
    let persons: [PodcastPerson]

    var body: some View {
        if !self.persons.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: self.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(self.persons.enumerated()), id: \.offset) { _, person in
                            PodcastPersonCard(person: person)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - PodcastPersonCard

private struct PodcastPersonCard: View {
    let person: PodcastPerson

    var body: some View {
        if let href = person.href, let url = URL(string: href) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                self.card
            }
            .buttonStyle(.plain)
            .help(href)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(self.person.name)
            .accessibilityValue(self.roleLabel)
            .accessibilityHint(L10n.string("Opens profile in browser"))
        } else {
            self.card
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(self.person.name)
                .accessibilityValue(self.roleLabel)
        }
    }

    private var card: some View {
        VStack(spacing: 4) {
            self.avatar
            Text(verbatim: self.person.name)
                .font(.caption)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(verbatim: self.roleLabel)
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 76)
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        Group {
            if let img = person.imageURL, let url = URL(string: img) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    self.placeholder
                }
            } else {
                self.placeholder
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .foregroundStyle(.tertiary)
    }

    /// Role shown under the name. The Podcast Taxonomy is an English vocabulary, so
    /// it is title-cased and rendered verbatim (matching how categories are shown);
    /// the spec default when the attribute is absent is "host".
    private var roleLabel: String {
        (self.person.role ?? "host").capitalized
    }
}
