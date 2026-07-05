import Acoustics
import SwiftUI

// MARK: - IdentifyFieldResolver

/// Resolves the "current → proposed" pair for every `IdentifyTagField`, scoped
/// to the release chosen in the picker. One shared implementation drives the
/// grid rows, the default tick-state, and the advanced-field count so they can
/// never disagree.
struct IdentifyFieldResolver {
    let candidate: IdentificationCandidate
    let release: ReleaseOption?
    let currentValues: CurrentTagValues

    /// The value the candidate offers for `field`, or nil when it has none.
    /// Release-scoped fields follow the selected release; the candidate's
    /// top-level values (mirroring the best-ranked release) are the fallback.
    func proposed(for field: IdentifyTagField) -> String? {
        switch field {
        case .title:
            self.candidate.title

        case .artist:
            self.candidate.artist

        case .albumArtist:
            self.release?.albumArtist ?? self.candidate.albumArtist

        case .album:
            self.release?.title ?? self.candidate.album

        case .genre:
            self.candidate.genre

        case .trackNumber:
            (self.release == nil ? self.candidate.trackNumber : self.release?.trackNumber)
                .map(String.init)

        case .discNumber:
            (self.release == nil ? self.candidate.discNumber : self.release?.discNumber)
                .map(String.init)

        case .year:
            (self.release == nil ? self.candidate.year : self.release?.year)
                .map(String.init)

        case .trackTotal:
            self.release?.trackTotal.map(String.init)

        case .discTotal:
            self.release?.discTotal.map(String.init)

        case .isrc:
            self.candidate.isrcs.first

        case .mbRecordingID:
            self.candidate.mbRecordingID

        case .mbReleaseID:
            self.release?.id

        case .mbReleaseGroupID:
            self.release?.releaseGroupID

        case .mbAlbumArtistID:
            self.release?.albumArtistMBID
        }
    }

    /// The track's current value for `field`, empty string when unset.
    func current(for field: IdentifyTagField) -> String {
        switch field {
        case .title:
            self.currentValues.title ?? ""

        case .artist:
            self.currentValues.artist ?? ""

        case .albumArtist:
            self.currentValues.albumArtist ?? ""

        case .album:
            self.currentValues.album ?? ""

        case .genre:
            self.currentValues.genre ?? ""

        case .trackNumber:
            self.currentValues.trackNumber.map(String.init) ?? ""

        case .discNumber:
            self.currentValues.discNumber.map(String.init) ?? ""

        case .year:
            self.currentValues.year.map(String.init) ?? ""

        case .trackTotal:
            self.currentValues.trackTotal.map(String.init) ?? ""

        case .discTotal:
            self.currentValues.discTotal.map(String.init) ?? ""

        case .isrc:
            self.currentValues.isrc ?? ""

        case .mbRecordingID:
            self.currentValues.mbRecordingID ?? ""

        case .mbReleaseID:
            self.currentValues.mbReleaseID ?? ""

        case .mbReleaseGroupID:
            self.currentValues.mbReleaseGroupID ?? ""

        case .mbAlbumArtistID:
            self.currentValues.mbAlbumArtistID ?? ""
        }
    }

    /// Fields the candidate carries in `tier`, in display order.
    func availableFields(tier: IdentifyTagField.Tier) -> [IdentifyTagField] {
        IdentifyTagField.allCases.filter { $0.tier == tier && self.proposed(for: $0) != nil }
    }

    /// Default tick-state. Primary fields: ticked when the proposal differs
    /// from the current value (a visible change). Advanced fields: ticked only
    /// when the track has no current value — a missing identifier is a safe
    /// add, but an existing one that differs usually means the file was tagged
    /// against a different release on purpose, so it defaults unticked.
    func defaultSelection() -> Set<IdentifyTagField> {
        var fields: Set<IdentifyTagField> = []
        for field in IdentifyTagField.allCases {
            guard let proposal = self.proposed(for: field), !proposal.isEmpty else { continue }
            let currentValue = self.current(for: field)
            switch field.tier {
            case .primary:
                if proposal != currentValue { fields.insert(field) }

            case .advanced:
                if currentValue.isEmpty { fields.insert(field) }
            }
        }
        return fields
    }
}

// MARK: - FieldSelectionGrid

/// The per-field "current → proposed" diff table with opt-in checkboxes.
/// Primary fields are always visible; identifier-grade fields (MBIDs, ISRC,
/// totals) sit behind a "Show advanced fields" disclosure, collapsed by default.
struct FieldSelectionGrid: View {
    let resolver: IdentifyFieldResolver
    @Binding var selection: Set<IdentifyTagField>

    @State private var showAdvanced: Bool

    init(
        resolver: IdentifyFieldResolver,
        selection: Binding<Set<IdentifyTagField>>,
        initiallyShowAdvanced: Bool = false
    ) {
        self.resolver = resolver
        self._selection = selection
        self._showAdvanced = State(initialValue: initiallyShowAdvanced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(self.resolver.availableFields(tier: .primary), id: \.self) { field in
                self.row(field: field)
            }

            let advanced = self.resolver.availableFields(tier: .advanced)
            if !advanced.isEmpty {
                Button {
                    withAnimation(.easeInOut) { self.showAdvanced.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(self.showAdvanced ? 90 : 0))
                        Text(self.showAdvanced
                            ? L10n.string("Hide advanced fields")
                            : L10n.string("Show advanced fields (\(advanced.count))"))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .help(L10n.string("Identifiers and totals: ISRC, MusicBrainz IDs"))

                if self.showAdvanced {
                    ForEach(advanced, id: \.self) { field in
                        self.row(field: field)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.leading, 4)
    }

    private func row(field: IdentifyTagField) -> some View {
        let current = self.resolver.current(for: field)
        let proposed = self.resolver.proposed(for: field) ?? ""
        let isOn = Binding<Bool>(
            get: { self.selection.contains(field) },
            set: { newValue in
                if newValue { self.selection.insert(field) } else { self.selection.remove(field) }
            }
        )
        let unchanged = current == proposed && !current.isEmpty
        let currentSpoken = current.isEmpty ? L10n.string("empty") : current
        let valueFont: Font = field.isIdentifierValue ? .callout.monospaced() : .callout
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(
                    L10n.string("Accept \(field.displayName), currently \(currentSpoken), proposed \(proposed)")
                )
                .disabled(unchanged)
            Text(field.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(current.isEmpty ? "—" : current)
                .font(valueFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(field.isIdentifierValue ? .middle : .tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(proposed)
                .font(valueFont)
                .foregroundStyle(unchanged ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(field.isIdentifierValue ? .middle : .tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
