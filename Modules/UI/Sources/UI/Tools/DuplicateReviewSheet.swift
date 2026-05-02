import Persistence
import SwiftUI

// MARK: - DuplicateReviewSheet

/// Sheet for reviewing and removing duplicate tracks.
///
/// Groups tracks that share the same title, artist, and duration
/// (within one second). The user can soft-delete duplicates via "Remove".
public struct DuplicateReviewSheet: View {
    // MARK: - Dependencies

    /// The view-model driving this sheet.
    @ObservedObject public var vm: DuplicateReviewViewModel

    /// Controls sheet presentation.
    @Binding public var isPresented: Bool

    // MARK: - Init

    /// Creates the sheet with a view-model and a presentation binding.
    public init(vm: DuplicateReviewViewModel, isPresented: Binding<Bool>) {
        self.vm = vm
        self._isPresented = isPresented
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider()
            self.content
            Divider()
            self.footer
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 440)
        .task { await self.vm.load() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Find Duplicates")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if !self.vm.groups.isEmpty {
                    Text("\(self.vm.groups.count) group\(self.vm.groups.count == 1 ? "" : "s") found")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if self.vm.isLoading {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
        } else if let err = self.vm.loadError {
            ContentUnavailableView {
                Label("Could Not Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            }
        } else if self.vm.groups.isEmpty {
            ContentUnavailableView {
                Label("No Duplicates Found", systemImage: "checkmark.seal")
            } description: {
                Text("No tracks in your library share the same title, artist and duration.")
            }
        } else {
            List(self.vm.groups) { group in
                DuplicateGroupRow(group: group) { trackID in
                    Task { await self.vm.removeTrack(id: trackID) }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if let err = self.vm.loadError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            Button("Done") { self.isPresented = false }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - DuplicateGroupRow

/// A single row representing one duplicate group in the list.
private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let onRemove: (Int64) -> Void

    var body: some View {
        Section {
            ForEach(self.group.tracks, id: \.id) { track in
                TrackDuplicateRow(track: track, onRemove: self.onRemove)
            }
        } header: {
            HStack(spacing: 4) {
                Text(self.group.representativeTitle)
                    .font(.callout.weight(.semibold))
                if !self.group.representativeArtist.isEmpty {
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(self.group.representativeArtist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(self.group.tracks.count) copies")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - TrackDuplicateRow

/// A single track row inside a duplicate group.
private struct TrackDuplicateRow: View {
    let track: Track
    let onRemove: (Int64) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(string: self.track.fileURL)?.lastPathComponent ?? self.track.fileURL)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if let bitrate = self.track.bitrate {
                        Text("\(bitrate) kbps")
                    }
                    Text(Self.formatDuration(self.track.duration))
                    Text(Self.formatSize(self.track.fileSize))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") {
                if let id = self.track.id {
                    self.onRemove(id)
                }
            }
            .foregroundStyle(.red)
            .help("Remove this track from the library (does not delete the file)")
        }
        .padding(.vertical, 2)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private static func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 100 {
            return String(format: "%.0f MB", mb)
        }
        return String(format: "%.1f MB", mb)
    }
}
