import SwiftUI

// MARK: - BatchCoverArtSheet

/// Sheet showing progress for the "Fetch Missing Cover Art" batch operation.
public struct BatchCoverArtSheet: View {
    // MARK: - Dependencies

    /// The view-model driving this sheet.
    @ObservedObject public var vm: BatchCoverArtViewModel

    /// Controls sheet presentation.
    @Binding public var isPresented: Bool

    // MARK: - Init

    /// Creates the sheet with a view-model and a presentation binding.
    public init(vm: BatchCoverArtViewModel, isPresented: Binding<Bool>) {
        self.vm = vm
        self._isPresented = isPresented
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.header
            self.progressSection
            self.errorSection
            self.completionBadge
            Spacer()
            self.footerButtons
        }
        .padding(24)
        .frame(minWidth: 400, idealWidth: 460, minHeight: 220)
    }

    // MARK: - Subviews

    private var header: some View {
        Text("Fetch Missing Cover Art")
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var progressSection: some View {
        if self.vm.isRunning || self.vm.isDone {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(
                    value: self.vm.total > 0
                        ? Double(self.vm.processed) / Double(self.vm.total)
                        : 0
                )
                .progressViewStyle(.linear)
                .accessibilityLabel("Progress: \(self.vm.processed) of \(self.vm.total)")

                if !self.vm.currentAlbumTitle.isEmpty, self.vm.isRunning {
                    Text(self.vm.currentAlbumTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("Searching for \(self.vm.currentAlbumTitle)")
                }

                HStack {
                    Text("\(self.vm.processed) of \(self.vm.total) checked")
                    Spacer()
                    Text("\(self.vm.found) found")
                }
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }
        } else {
            Text(
                "This will search MusicBrainz for front cover art for every album " +
                    "in your library that currently has no artwork. One album is " +
                    "requested per second to respect the MusicBrainz rate limit."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let err = self.vm.lastError {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var completionBadge: some View {
        if self.vm.isDone {
            Label(
                "Done — \(self.vm.found) image\(self.vm.found == 1 ? "" : "s") saved",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.callout.weight(.medium))
            .accessibilityLabel("Completed. \(self.vm.found) images saved.")
        }
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            if self.vm.isRunning {
                Button("Cancel") { self.vm.cancel() }
                    .accessibilityHint("Stops the batch fetch operation")
            } else if self.vm.isDone {
                Button("Close") { self.isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button("Cancel") { self.isPresented = false }
                Button("Start") { self.vm.start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Begins fetching missing cover art from MusicBrainz")
            }
        }
    }
}
