import Acoustics
import SwiftUI

// MARK: - CandidatePickerView

/// Displays the ranked list of identification candidates for the user to pick from.
///
/// Each row is expandable into a per-field selector: the user ticks the
/// individual fields they want to accept ("Apply selected") rather than
/// having every tag overwritten in one go.
struct CandidatePickerView: View {
    let candidates: [IdentificationCandidate]
    let currentValues: CurrentTagValues
    let onApply: (IdentificationCandidate, Set<IdentifyTagField>) async -> Void
    let onSkip: () -> Void

    @State private var expandedID: String?
    @State private var applying: String?
    @State private var applied: String?
    @State private var fieldSelection: [String: Set<IdentifyTagField>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select a match")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 4)

            Text("Tick the fields you want to accept — anything unchecked is left as-is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

            if let topScore = self.candidates.first?.score, topScore < 0.6 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Low confidence — verify tags before applying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
                .padding(.bottom, 6)
                .accessibilityLabel("Warning: low confidence match — verify tags before applying")
            }

            Divider()

            List(self.candidates) { candidate in
                CandidateRow(
                    candidate: candidate,
                    currentValues: self.currentValues,
                    selection: self.binding(for: candidate),
                    isExpanded: self.expandedID == candidate.id,
                    isApplying: self.applying == candidate.id,
                    isApplied: self.applied == candidate.id,
                    onToggle: {
                        withAnimation(.easeInOut) {
                            if self.expandedID == candidate.id {
                                self.expandedID = nil
                            } else {
                                self.expandedID = candidate.id
                                if self.fieldSelection[candidate.id] == nil {
                                    self.fieldSelection[candidate.id] = Self.defaultSelection(
                                        candidate: candidate,
                                        current: self.currentValues
                                    )
                                }
                            }
                        }
                    },
                    onApply: {
                        let fields = self.fieldSelection[candidate.id] ?? Self.defaultSelection(
                            candidate: candidate,
                            current: self.currentValues
                        )
                        self.applying = candidate.id
                        Task {
                            await self.onApply(candidate, fields)
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
                Button("Skip", action: self.onSkip)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Skip this track without applying changes")
            }
            .padding()
        }
    }

    private func binding(for candidate: IdentificationCandidate) -> Binding<Set<IdentifyTagField>> {
        Binding(
            get: {
                self.fieldSelection[candidate.id] ?? Self.defaultSelection(
                    candidate: candidate,
                    current: self.currentValues
                )
            },
            set: { self.fieldSelection[candidate.id] = $0 }
        )
    }

    /// Default to selecting fields where the candidate offers a value that
    /// differs from the current track value (and ignoring fields the
    /// candidate doesn't carry).
    private static func defaultSelection(
        candidate: IdentificationCandidate,
        current: CurrentTagValues
    ) -> Set<IdentifyTagField> {
        var fields: Set<IdentifyTagField> = []
        if candidate.title != (current.title ?? "") { fields.insert(.title) }
        if candidate.artist != (current.artist ?? "") { fields.insert(.artist) }
        if let albumArtist = candidate.albumArtist, albumArtist != (current.albumArtist ?? "") {
            fields.insert(.albumArtist)
        }
        if let album = candidate.album, album != (current.album ?? "") { fields.insert(.album) }
        if let genre = candidate.genre, genre != (current.genre ?? "") { fields.insert(.genre) }
        if let trackNumber = candidate.trackNumber, trackNumber != (current.trackNumber ?? -1) {
            fields.insert(.trackNumber)
        }
        if let discNumber = candidate.discNumber, discNumber != (current.discNumber ?? -1) {
            fields.insert(.discNumber)
        }
        if let year = candidate.year, year != (current.year ?? -1) { fields.insert(.year) }
        return fields
    }
}

// MARK: - CandidateRow

private struct CandidateRow: View {
    let candidate: IdentificationCandidate
    let currentValues: CurrentTagValues
    @Binding var selection: Set<IdentifyTagField>
    let isExpanded: Bool
    let isApplying: Bool
    let isApplied: Bool
    let onToggle: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: self.onToggle) {
                HStack(alignment: .top, spacing: 12) {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(self.candidate.title) by \(self.candidate.artist), confidence \(Int(self.candidate.score * 100))%"
            )

            if self.isExpanded {
                FieldSelectionGrid(
                    candidate: self.candidate,
                    currentValues: self.currentValues,
                    selection: self.$selection
                )
                .transition(.opacity.combined(with: .move(edge: .top)))

                if let mbid = self.candidate.mbRecordingID {
                    HStack(spacing: 6) {
                        Text("MBID")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(mbid)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.top, 2)
                }

                HStack {
                    Button("Select All") { self.selectAll() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Select all available tag fields")
                    Button("Select None") { self.selection.removeAll() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Deselect all tag fields")
                    Spacer()
                    if self.isApplied {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    } else {
                        Button("Apply Selected") { self.onApply() }
                            .buttonStyle(.borderedProminent)
                            .disabled(self.selection.isEmpty || self.isApplying)
                            .help("Write selected fields to the track's tags")
                            .overlay {
                                if self.isApplying {
                                    ProgressView().scaleEffect(0.7)
                                }
                            }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func selectAll() {
        self.selection = Set(IdentifyTagField.allCases.filter { Self.candidateHasValue($0, candidate: self.candidate) })
    }

    private static func candidateHasValue(
        _ field: IdentifyTagField,
        candidate: IdentificationCandidate
    ) -> Bool {
        switch field {
        case .title, .artist:
            true

        case .albumArtist:
            candidate.albumArtist != nil

        case .album:
            candidate.album != nil

        case .genre:
            candidate.genre != nil

        case .trackNumber:
            candidate.trackNumber != nil

        case .discNumber:
            candidate.discNumber != nil

        case .year:
            candidate.year != nil
        }
    }
}

// MARK: - FieldSelectionGrid

private struct FieldSelectionGrid: View {
    let candidate: IdentificationCandidate
    let currentValues: CurrentTagValues
    @Binding var selection: Set<IdentifyTagField>

    var body: some View {
        VStack(spacing: 4) {
            ForEach(IdentifyTagField.allCases, id: \.self) { field in
                if let proposed = self.proposed(for: field) {
                    self.row(field: field, current: self.current(for: field), proposed: proposed)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func row(field: IdentifyTagField, current: String, proposed: String) -> some View {
        let isOn = Binding<Bool>(
            get: { self.selection.contains(field) },
            set: { newValue in
                if newValue { self.selection.insert(field) } else { self.selection.remove(field) }
            }
        )
        let unchanged = current == proposed && !current.isEmpty
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Accept \(field.displayName)")
                .disabled(unchanged)
            Text(field.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(current.isEmpty ? "—" : current)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(proposed)
                .font(.caption)
                .foregroundStyle(unchanged ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func proposed(for field: IdentifyTagField) -> String? {
        switch field {
        case .title:
            self.candidate.title

        case .artist:
            self.candidate.artist

        case .albumArtist:
            self.candidate.albumArtist

        case .album:
            self.candidate.album

        case .genre:
            self.candidate.genre

        case .trackNumber:
            self.candidate.trackNumber.map(String.init)

        case .discNumber:
            self.candidate.discNumber.map(String.init)

        case .year:
            self.candidate.year.map(String.init)
        }
    }

    private func current(for field: IdentifyTagField) -> String {
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
        }
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
            Text("\(self.percent)%")
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
        .accessibilityLabel("Confidence \(self.percent)%")
    }
}
