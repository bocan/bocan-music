import SwiftUI

// MARK: - ScanProgressPane

/// Full-pane progress view shown during an initial library scan when there are
/// no existing tracks to display in the content area.
///
/// Dismissed automatically once the post-scan `tracks.load()` completes —
/// the transition to the populated track list is immediate with no empty-state
/// flash.  For re-scans (library already populated) this view is never shown;
/// the existing track list remains visible throughout.
struct ScanProgressPane: View {
    let walked: Int
    let inserted: Int
    let currentPath: String

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .padding(.bottom, 4)

            VStack(spacing: 6) {
                Text("Scanning Library")
                    .font(.title2.weight(.semibold))

                if self.walked > 0 {
                    Text("\(self.walked.formatted()) files found")
                        .foregroundStyle(.secondary)

                    if self.inserted > 0 {
                        Text("\(self.inserted.formatted()) added to library")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Looking for music files…")
                        .foregroundStyle(.secondary)
                }
            }

            if !self.currentPath.isEmpty {
                Text(self.currentPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            self.walked > 0
                ? "Scanning library. \(self.walked.formatted()) files found, \(self.inserted.formatted()) added."
                : "Scanning library. Looking for music files."
        )
    }
}
