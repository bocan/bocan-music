import Acoustics
import Library
import Persistence
import SwiftUI

// MARK: - IdentifyTrackSheet

/// Modal sheet for acoustic track identification.
///
/// Triggered by context menu "Identify Track…", toolbar button, or ⌘⌥I.
/// Drives through states: fingerprinting → looking up → results / no match / error.
public struct IdentifyTrackSheet: View {
    @ObservedObject public var vm: IdentifyTrackViewModel
    @Environment(\.dismiss) private var dismiss

    public init(vm: IdentifyTrackViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Identify Track")
                    .font(.title2.bold())
                Spacer()
                Button("Close", systemImage: "xmark.circle.fill") {
                    self.vm.cancel()
                    self.dismiss()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close")
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            Divider()

            self.phaseContent
                .frame(minWidth: 480, minHeight: 280)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 320)
        .task { self.vm.start() }
    }

    // MARK: - Phase content

    @ViewBuilder
    private var phaseContent: some View {
        switch self.vm.phase {
        case .fingerprinting:
            self.spinnerView(label: "Computing fingerprint…")

        case .lookingUp:
            self.spinnerView(label: "Looking up…")

        case let .results(candidates):
            CandidatePickerView(
                candidates: candidates,
                currentValues: self.vm.currentValues,
                onApply: { candidate, fields in
                    await self.vm.apply(candidate, fields: fields)
                    if self.vm.didApply {
                        self.dismiss()
                    }
                },
                onSkip: {
                    self.vm.cancel()
                    self.dismiss()
                }
            )

        case .noMatch:
            self.noMatchView

        case let .error(message):
            self.errorView(message: message)
        }
    }

    // MARK: - Sub-views

    private func spinnerView(label: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)
                .accessibilityLabel(label)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchView: some View {
        ContentUnavailableView {
            Label("No Match Found", systemImage: "music.note.list")
        } description: {
            Text("No AcoustID match was found for this track. Try editing tags manually.")
        } actions: {
            Button("Edit Tags") {
                self.vm.requestTagEditor()
                self.dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func errorView(message: String) -> some View {
        ContentUnavailableView {
            Label("Identification Failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .multilineTextAlignment(.center)
        } actions: {
            Button("Retry") {
                self.vm.retry()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
