import SwiftUI

// MARK: - PhoneSyncPairingSheet

/// The pairing modal (sync-protocol.md section 4): waiting -> show-code ->
/// confirm -> result. The confirm step is the mandatory human check and cannot
/// be skipped.
struct PhoneSyncPairingSheet: View {
    @ObservedObject var viewModel: PhoneSyncViewModel

    var body: some View {
        VStack(spacing: 20) {
            switch self.viewModel.pairingSheet {
            case .waiting, .none:
                self.waiting

            case let .code(code):
                self.codeView(code)

            case let .confirm(deviceName, fingerprintTail):
                self.confirm(deviceName: deviceName, fingerprintTail: fingerprintTail)

            case let .result(outcome):
                self.result(outcome)
            }
        }
        .padding(28)
        .frame(width: 360)
        .multilineTextAlignment(.center)
    }

    // MARK: - Waiting

    private var waiting: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(localized: "Open Bòcan on your phone and tap this Mac.")
            self.cancelButton
        }
    }

    // MARK: - Show code

    private func codeView(_ code: String) -> some View {
        VStack(spacing: 16) {
            Text(localized: "Enter this code on your phone.")
            Text(self.grouped(code))
                .font(.system(size: 42, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel(L10n.string("Pairing code"))
                .accessibilityValue(self.spelledOut(code))
            self.cancelButton
        }
    }

    // MARK: - Confirm

    private func confirm(deviceName: String, fingerprintTail: String) -> some View {
        VStack(spacing: 16) {
            Text(localized: "Pair with this phone?")
                .font(.headline)
            Text(deviceName)
                .font(.title3)
            Text(localized: "Only accept if the phone shows Paired.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LabeledContent {
                Text(fingerprintTail)
                    .font(.system(.footnote, design: .monospaced))
            } label: {
                Text(localized: "Fingerprint")
            }
            HStack {
                Button(role: .cancel) {
                    self.viewModel.confirmTrust(false)
                } label: {
                    Text(localized: "Cancel")
                }
                Button {
                    self.viewModel.confirmTrust(true)
                } label: {
                    Text(localized: "Trust")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Result

    private func result(_ outcome: PhoneSyncPairingOutcome) -> some View {
        VStack(spacing: 16) {
            Image(systemName: self.resultSymbol(outcome))
                .font(.system(size: 40))
                .foregroundStyle(self.resultTint(outcome))
            Text(self.resultTitle(outcome))
                .font(.headline)
            if case let .paired(deviceName) = outcome {
                Text(deviceName)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await self.viewModel.dismissPairing() }
            } label: {
                Text(localized: "Done")
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Shared

    private var cancelButton: some View {
        Button(role: .cancel) {
            Task { await self.viewModel.dismissPairing() }
        } label: {
            Text(localized: "Cancel")
        }
    }

    private func resultTitle(_ outcome: PhoneSyncPairingOutcome) -> String {
        switch outcome {
        case .paired:
            L10n.string("Paired")

        case .codeMismatch:
            L10n.string("This code did not match.")

        case .timedOut:
            L10n.string("Pairing timed out.")

        case .cancelled:
            L10n.string("Pairing cancelled.")

        case .failed:
            L10n.string("Pairing failed.")
        }
    }

    private func resultSymbol(_ outcome: PhoneSyncPairingOutcome) -> String {
        if case .paired = outcome { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private func resultTint(_ outcome: PhoneSyncPairingOutcome) -> Color {
        if case .paired = outcome { return .green }
        return .orange
    }

    /// Groups the six digits as "123 456" for legibility.
    private func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<mid]) \(code[mid...])"
    }

    /// Spells the digits out so VoiceOver reads them individually.
    private func spelledOut(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }
}
