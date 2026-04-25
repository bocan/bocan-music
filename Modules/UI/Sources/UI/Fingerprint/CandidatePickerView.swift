import Acoustics
import SwiftUI

// MARK: - CandidatePickerView

/// Displays the ranked list of identification candidates for the user to pick from.
struct CandidatePickerView: View {
    let candidates: [IdentificationCandidate]
    let onApply: (IdentificationCandidate) async -> Void
    let onSkip: () -> Void

    @State private var expandedID: String?
    @State private var applying: String?
    @State private var applied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select a match")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()

            List(self.candidates) { candidate in
                CandidateRow(
                    candidate: candidate,
                    isExpanded: self.expandedID == candidate.id,
                    isApplying: self.applying == candidate.id,
                    isApplied: self.applied == candidate.id,
                    onToggle: {
                        withAnimation(.easeInOut) {
                            self.expandedID = self.expandedID == candidate.id ? nil : candidate.id
                        }
                    },
                    onApply: {
                        self.applying = candidate.id
                        Task {
                            await self.onApply(candidate)
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
            }
            .padding()
        }
    }
}

// MARK: - CandidateRow

private struct CandidateRow: View {
    let candidate: IdentificationCandidate
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
                self.detailGrid
                    .transition(.opacity.combined(with: .move(edge: .top)))

                HStack {
                    Spacer()
                    if self.isApplied {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    } else {
                        Button("Apply") {
                            self.onApply()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(self.isApplying)
                        .overlay {
                            if self.isApplying {
                                ProgressView()
                                    .scaleEffect(0.7)
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

    private var detailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            if let albumArtist = self.candidate.albumArtist {
                GridRow {
                    Text("Album Artist").foregroundStyle(.secondary).font(.caption)
                    Text(albumArtist).font(.caption)
                }
            }
            if let trackNumber = self.candidate.trackNumber {
                GridRow {
                    Text("Track").foregroundStyle(.secondary).font(.caption)
                    Text(String(trackNumber)).font(.caption)
                }
            }
            if let discNumber = self.candidate.discNumber {
                GridRow {
                    Text("Disc").foregroundStyle(.secondary).font(.caption)
                    Text(String(discNumber)).font(.caption)
                }
            }
            if let label = self.candidate.label {
                GridRow {
                    Text("Label").foregroundStyle(.secondary).font(.caption)
                    Text(label).font(.caption)
                }
            }
            if let genre = self.candidate.genre {
                GridRow {
                    Text("Genre").foregroundStyle(.secondary).font(.caption)
                    Text(genre).font(.caption)
                }
            }
            if let mbid = self.candidate.mbRecordingID {
                GridRow {
                    Text("MBID").foregroundStyle(.secondary).font(.caption)
                    Text(mbid).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 4)
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
