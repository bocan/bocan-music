import Acoustics
import SwiftUI

// MARK: - CandidatePickerView

/// Displays the ranked list of identification candidates for the user to pick from.
///
/// Each row is expandable into a per-field selector: the user picks which
/// release to tag against (original pressing, remaster, compilation…), then
/// ticks the individual fields they want to accept ("Apply selected") rather
/// than having every tag overwritten in one go.
struct CandidatePickerView: View {
    let candidates: [IdentificationCandidate]
    let currentValues: CurrentTagValues
    let onApply: (IdentificationCandidate, Set<IdentifyTagField>, ReleaseOption?) async -> Void
    let onSkip: () -> Void

    @State private var expandedID: String?
    @State private var applying: String?
    @State private var applied: String?
    @State private var fieldSelection: [String: Set<IdentifyTagField>] = [:]
    /// Per-candidate release choice (candidate id → release id). Falls back to
    /// the best-ranked release when the user hasn't picked one.
    @State private var selectedReleaseID: [String: String] = [:]

    private let initiallyShowAdvanced: Bool

    init(
        candidates: [IdentificationCandidate],
        currentValues: CurrentTagValues,
        onApply: @escaping (IdentificationCandidate, Set<IdentifyTagField>, ReleaseOption?) async -> Void,
        onSkip: @escaping () -> Void,
        initiallyExpanded: String? = nil,
        initiallyShowAdvanced: Bool = false
    ) {
        self.candidates = candidates
        self.currentValues = currentValues
        self.onApply = onApply
        self.onSkip = onSkip
        self._expandedID = State(initialValue: initiallyExpanded)
        self.initiallyShowAdvanced = initiallyShowAdvanced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localized: "Select a match")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 4)

            Text(localized: "Tick the fields you want to accept — anything unchecked is left as-is.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

            if let topScore = self.candidates.first?.score, topScore < 0.6 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(localized: "Low confidence — verify tags before applying.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
                .padding(.bottom, 6)
                .accessibilityLabel(L10n.string("Warning: low confidence match — verify tags before applying"))
            }

            Divider()

            List(self.candidates) { candidate in
                CandidateRow(
                    candidate: candidate,
                    release: self.resolvedRelease(for: candidate),
                    currentValues: self.currentValues,
                    selection: self.binding(for: candidate),
                    isExpanded: self.expandedID == candidate.id,
                    isApplying: self.applying == candidate.id,
                    isApplied: self.applied == candidate.id,
                    initiallyShowAdvanced: self.initiallyShowAdvanced,
                    onToggle: {
                        withAnimation(.easeInOut) {
                            if self.expandedID == candidate.id {
                                self.expandedID = nil
                            } else {
                                self.expandedID = candidate.id
                                if self.fieldSelection[candidate.id] == nil {
                                    self.fieldSelection[candidate.id] = self.resolver(for: candidate)
                                        .defaultSelection()
                                }
                            }
                        }
                    },
                    onSelectRelease: { release in
                        self.selectedReleaseID[candidate.id] = release.id
                        // A different release changes the proposed values, so the
                        // tick defaults are stale — recompute them for the new release.
                        self.fieldSelection[candidate.id] = IdentifyFieldResolver(
                            candidate: candidate,
                            release: release,
                            currentValues: self.currentValues
                        ).defaultSelection()
                    },
                    onApply: {
                        let fields = self.fieldSelection[candidate.id] ?? self.resolver(for: candidate)
                            .defaultSelection()
                        let release = self.resolvedRelease(for: candidate)
                        self.applying = candidate.id
                        Task {
                            await self.onApply(candidate, fields, release)
                            self.applied = candidate.id
                            self.applying = nil
                        }
                    }
                )
            }
            .listStyle(.plain)

            Divider()

            HStack {
                Spacer()
                Button(L10n.string("Skip"), action: self.onSkip)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help(L10n.string("Skip this track without applying changes"))
            }
            .padding()
        }
    }

    // MARK: - Helpers

    private func resolvedRelease(for candidate: IdentificationCandidate) -> ReleaseOption? {
        if let selectedID = self.selectedReleaseID[candidate.id],
           let selected = candidate.releases.first(where: { $0.id == selectedID }) {
            return selected
        }
        return candidate.releases.first
    }

    private func resolver(for candidate: IdentificationCandidate) -> IdentifyFieldResolver {
        IdentifyFieldResolver(
            candidate: candidate,
            release: self.resolvedRelease(for: candidate),
            currentValues: self.currentValues
        )
    }

    private func binding(for candidate: IdentificationCandidate) -> Binding<Set<IdentifyTagField>> {
        Binding(
            get: {
                self.fieldSelection[candidate.id] ?? self.resolver(for: candidate).defaultSelection()
            },
            set: { self.fieldSelection[candidate.id] = $0 }
        )
    }
}

// MARK: - CandidateRow

private struct CandidateRow: View {
    let candidate: IdentificationCandidate
    let release: ReleaseOption?
    let currentValues: CurrentTagValues
    @Binding var selection: Set<IdentifyTagField>
    let isExpanded: Bool
    let isApplying: Bool
    let isApplied: Bool
    let initiallyShowAdvanced: Bool
    let onToggle: () -> Void
    let onSelectRelease: (ReleaseOption) -> Void
    let onApply: () -> Void

    @State private var isHovering = false

    private var resolver: IdentifyFieldResolver {
        IdentifyFieldResolver(
            candidate: self.candidate,
            release: self.release,
            currentValues: self.currentValues
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: self.onToggle) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(self.isExpanded ? 90 : 0))
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(self.candidate.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(self.candidate.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let album = self.candidate.album {
                            Text(album)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        ConfidenceBadge(score: self.candidate.score)
                        if let year = self.candidate.year {
                            Text(String(year))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                // The whole row must hit-test, including the transparent gap the
                // Spacer leaves between title and badge — a plain Button only hits
                // its opaque label content otherwise.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.isHovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .onHover { self.isHovering = $0 }
            .accessibilityLabel(
                L10n.string("\(self.candidate.title) by \(self.candidate.artist), confidence \(Int(self.candidate.score * 100))%")
            )
            .accessibilityHint(L10n.string("Expands to choose which fields to apply"))

            if self.isExpanded {
                self.expandedContent
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var expandedContent: some View {
        if !self.candidate.releases.isEmpty, let release = self.release {
            ReleasePickerControl(
                releases: self.candidate.releases,
                selected: release,
                onSelect: self.onSelectRelease
            )
            .padding(.leading, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        FieldSelectionGrid(
            resolver: self.resolver,
            selection: self.$selection,
            initiallyShowAdvanced: self.initiallyShowAdvanced
        )
        .transition(.opacity.combined(with: .move(edge: .top)))

        HStack {
            Button(L10n.string("Select All")) { self.selectAll() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(L10n.string("Select all available tag fields"))
            Button(L10n.string("Select None")) { self.selection.removeAll() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(L10n.string("Deselect all tag fields"))
            Spacer()
            if self.isApplied {
                Label(L10n.string("Applied"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                Button(L10n.string("Apply Selected")) { self.onApply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.selection.isEmpty || self.isApplying)
                    .help(L10n.string("Write selected fields to the track's tags (Return)"))
                    .overlay {
                        if self.isApplying {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
            }
        }
        .padding(.top, 4)
    }

    private func selectAll() {
        self.selection = Set(
            self.resolver.availableFields(tier: .primary)
                + self.resolver.availableFields(tier: .advanced)
        )
    }
}

// MARK: - ConfidenceBadge

private struct ConfidenceBadge: View {
    let score: Double

    private var percent: Int {
        Int(self.score * 100)
    }

    private var color: Color {
        switch self.score {
        case 0.8...:
            .green

        case 0.5...:
            .yellow

        default:
            .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(localized: "\(self.percent)%")
                .font(.caption.bold())
                .foregroundStyle(self.color)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(self.color)
                        .frame(width: proxy.size.width * self.score)
                }
            }
            .frame(width: 48, height: 6)
        }
        .accessibilityLabel(L10n.string("Confidence \(self.percent)%"))
    }
}
