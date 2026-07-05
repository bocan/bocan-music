import Acoustics
import SwiftUI

// MARK: - ReleasePickerControl

/// Compact control showing the currently selected release of an identification
/// candidate, with a popover listing every release MusicBrainz returned so the
/// user can retag against the exact edition they own (original pressing,
/// remaster, territory variant, compilation…).
struct ReleasePickerControl: View {
    let releases: [ReleaseOption]
    let selected: ReleaseOption
    let onSelect: (ReleaseOption) -> Void

    @State private var isPickerPresented = false

    var body: some View {
        HStack(spacing: 6) {
            Text(localized: "Release")
                .font(.callout)
                .foregroundStyle(.secondary)

            if self.releases.count > 1 {
                Button {
                    self.isPickerPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.summary(for: self.selected))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.string("Choose which release to tag against"))
                .accessibilityLabel(L10n.string("Release: \(Self.summary(for: self.selected))"))
                .popover(isPresented: self.$isPickerPresented, arrowEdge: .bottom) {
                    ReleasePickerPopover(
                        releases: self.releases,
                        selectedID: self.selected.id
                    ) { release in
                        self.isPickerPresented = false
                        self.onSelect(release)
                    }
                }

                Text(verbatim: "(\(self.releases.count))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(L10n.string("\(self.releases.count) releases available"))
            } else {
                Text(Self.summary(for: self.selected))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    /// One-line summary: "Abbey Road · 1969 · GB · 12" Vinyl".
    static func summary(for release: ReleaseOption) -> String {
        var parts = [release.title]
        if let year = release.year { parts.append(String(year)) }
        if let country = release.country { parts.append(country) }
        if let format = release.mediaFormat { parts.append(format) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - ReleasePickerPopover

/// The popover list of releases: date, country, format, and status for each.
struct ReleasePickerPopover: View {
    let releases: [ReleaseOption]
    let selectedID: ReleaseOption.ID
    let onSelect: (ReleaseOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localized: "Select a release")
                .font(.headline)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(self.releases) { release in
                        self.row(for: release)
                        if release.id != self.releases.last?.id {
                            Divider().padding(.leading, 28)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(minWidth: 380, idealWidth: 440)
    }

    private func row(for release: ReleaseOption) -> some View {
        Button {
            self.onSelect(release)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(release.id == self.selectedID ? 1 : 0)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(release.title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        if let date = release.date {
                            Text(date)
                        }
                        if let country = release.country {
                            Text(country)
                        }
                        if let format = release.mediaFormat {
                            Text(format)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if let status = release.status, status != "Official" {
                    Text(Self.statusDisplayName(status))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(self.accessibilitySummary(for: release))
        .accessibilityAddTraits(release.id == self.selectedID ? .isSelected : [])
    }

    private func accessibilitySummary(for release: ReleaseOption) -> String {
        var parts = [ReleasePickerControl.summary(for: release)]
        if let status = release.status, status != "Official" {
            parts.append(Self.statusDisplayName(status))
        }
        return parts.joined(separator: ", ")
    }

    /// UI-side display mapping for MusicBrainz release statuses. The raw values
    /// are data owned by MusicBrainz; known ones get localized display names and
    /// unknown ones render verbatim.
    static func statusDisplayName(_ raw: String) -> String {
        switch raw {
        case "Promotion":
            L10n.string("Promo")

        case "Bootleg":
            L10n.string("Bootleg")

        case "Pseudo-Release":
            L10n.string("Pseudo-release")

        default:
            raw
        }
    }
}
