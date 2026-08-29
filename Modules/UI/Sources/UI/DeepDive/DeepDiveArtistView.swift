import Library
import SwiftUI

// MARK: - DeepDiveArtistView

/// The artist Deep Dive report: bio, details, members, discography, links (#413).
struct DeepDiveArtistView: View {
    @ObservedObject var vm: DeepDiveArtistViewModel

    var body: some View {
        Group {
            switch self.vm.state {
            case .idle, .loading:
                DeepDiveProgressView(retry: nil)

            case let .retrying(attempt, total):
                DeepDiveProgressView(retry: (attempt, total))

            case let .failed(error):
                DeepDiveErrorView(message: DeepDiveFormat.errorMessage(error)) { self.vm.load(forceRefresh: true) }

            case let .loaded(report):
                self.report(report)
            }
        }
        .task {
            if case .idle = self.vm.state { self.vm.load() }
        }
    }

    private func report(_ report: ArtistReport) -> some View {
        Form {
            if let bio = report.bio {
                self.bioSection(bio)
            }
            self.detailsSection(report)
            if !report.members.isEmpty {
                self.membersSection(report.members)
            }
            if !report.discography.isEmpty {
                self.discographySection(report.discography)
            }
            if !report.links.isEmpty {
                self.linksSection(report.links)
            }
            DeepDiveFooter(fetchedAt: report.fetchedAt, helpText: L10n.string("Fetch the report again from MusicBrainz and Wikipedia")) {
                self.vm.load(forceRefresh: true)
            }
        }
        .formStyle(.grouped)
    }

    private func bioSection(_ bio: ArtistReport.Bio) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                if let thumb = bio.thumbnailURL {
                    AsyncImage(url: thumb) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.bgTertiary
                    }
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                }
                Text(verbatim: bio.extract)
                    .font(Typography.body)
                    .textSelection(.enabled)
            }
            HStack {
                Text(verbatim: bio.attribution)
                    .font(Typography.mini)
                    .foregroundStyle(Color.textTertiary)
                if let page = bio.pageURL {
                    Link(L10n.string("Read on Wikipedia"), destination: page)
                        .font(Typography.mini)
                }
            }
        }
    }

    private func detailsSection(_ report: ArtistReport) -> some View {
        Section(L10n.string("Details")) {
            if report.mbidGuessed {
                HStack {
                    Label(L10n.string("Matched by name; the tags carry no MusicBrainz id."), systemImage: "questionmark.circle")
                        .font(Typography.caption)
                        .foregroundStyle(Color.warningTint)
                    Spacer()
                    Button(L10n.string("Use This Match")) { self.vm.confirmMBID() }
                        .help(L10n.string("Store this MusicBrainz id for the artist; a tagged id from a later scan replaces it"))
                }
            }
            if let type = report.type {
                LabeledContent(L10n.string("Type"), value: type)
            }
            if let country = report.country {
                LabeledContent(L10n.string("Country"), value: country)
            }
            if let span = DeepDiveFormat.span(begin: report.activeFrom, end: report.activeUntil, ended: report.ended) {
                LabeledContent(L10n.string("Active"), value: span)
            }
            if let disambiguation = report.disambiguation {
                LabeledContent(L10n.string("Disambiguation"), value: disambiguation)
            }
            ReadOnlyIDRow(label: L10n.string("Artist MBID"), value: report.mbid)
        }
    }

    private func membersSection(_ members: [ArtistReport.Member]) -> some View {
        Section(L10n.string("Members")) {
            ForEach(members, id: \.mbid) { member in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: member.name)
                        if !member.roles.isEmpty {
                            Text(verbatim: member.roles.joined(separator: ", "))
                                .font(Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    Spacer()
                    if let span = DeepDiveFormat.span(begin: member.begin, end: member.end, ended: member.ended) {
                        Text(verbatim: span)
                            .font(Typography.caption)
                            .foregroundStyle(member.ended ? Color.textTertiary : Color.textSecondary)
                    }
                }
            }
        }
    }

    private func discographySection(_ releases: [ArtistReport.Release]) -> some View {
        Section(L10n.string("Discography")) {
            ForEach(releases, id: \.mbid) { release in
                HStack {
                    Image(systemName: release.owned ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(release.owned ? Color.accentColor : Color.textTertiary)
                        .accessibilityLabel(release.owned ? L10n.string("In your library") : L10n.string("Not in your library"))
                    Text(verbatim: release.title)
                    Spacer()
                    Text(verbatim: DeepDiveFormat.releaseKind(release.primaryType, secondary: release.secondaryTypes))
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                    DeepDiveYear(year: release.year)
                }
            }
        }
    }

    private func linksSection(_ links: [ArtistReport.Link]) -> some View {
        Section(L10n.string("Links")) {
            ForEach(links, id: \.type) { link in
                Link(DeepDiveFormat.linkLabel(link.type), destination: link.url)
            }
        }
    }
}

// MARK: - Shared pieces

/// Right-aligned four-digit year column, blank when unknown.
struct DeepDiveYear: View {
    let year: Int?

    var body: some View {
        Text(verbatim: self.year.map(String.init) ?? "")
            .font(Typography.caption.monospacedDigit())
            .foregroundStyle(Color.textSecondary)
            .frame(width: 44, alignment: .trailing)
    }
}

/// "Fetched <date>" plus a Refresh button.
struct DeepDiveFooter: View {
    let fetchedAt: Date
    let helpText: String
    let refresh: () -> Void

    var body: some View {
        Section {
            HStack {
                Text(L10n.string("Fetched \(self.fetchedAt.formatted(date: .abbreviated, time: .shortened))"))
                    .font(Typography.mini)
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                Button(L10n.string("Refresh"), action: self.refresh)
                    .help(self.helpText)
            }
        }
    }
}

// MARK: - DeepDiveProgressView

/// The spinner while a report loads, with the retry countdown when
/// MusicBrainz has asked us to slow down.
struct DeepDiveProgressView: View {
    /// (attempt, total) while waiting to retry; nil on the first attempt.
    let retry: (Int, Int)?

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(L10n.string("Asking MusicBrainz…"))
            if let (attempt, total) = self.retry {
                Text(L10n.string("MusicBrainz asked us to slow down. Retrying (\(attempt) of \(total))…"))
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityLabel(L10n.string("Retrying, attempt \(attempt) of \(total)"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DeepDiveErrorView

struct DeepDiveErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.system(size: 28))
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
            Text(verbatim: self.message)
                .font(Typography.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            Button(L10n.string("Try Again"), action: self.retry)
                .help(L10n.string("Ask MusicBrainz again"))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
