import Observability
import SwiftUI

// MARK: - DiagnosticsConsentBanner

/// Non-modal consent prompt shown once at first launch.
///
/// Displayed as a `.safeAreaInset(edge: .top)` overlay in `BocanRootView` so
/// it never grabs keyboard focus, never triggers an NSAlert run-loop spin, and
/// therefore cannot cause an audio pop.  It collapses automatically once the
/// user responds (either accepting or declining).
struct DiagnosticsConsentBanner: View {
    @AppStorage(MetricKitListener.consentKey) private var consented = false
    @AppStorage(MetricKitListener.consentAskedKey) private var consentAsked = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(localized: "Help improve Bòcan by sharing anonymous crash reports?")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(self.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(L10n.string("Not Now")) {
                    self.consentAsked = true
                    self.consented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.string("Skip crash report sharing. You can enable it later in Settings › Diagnostics."))
                .accessibilityLabel(L10n.string("Decline crash report sharing"))

                Button(L10n.string("Share Crash Reports")) {
                    self.consented = true
                    self.consentAsked = true
                    MetricKitListener.shared.start()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(L10n.string("Share anonymous crash reports stored only on this Mac to help improve Bòcan."))
                .accessibilityLabel(L10n.string("Accept crash report sharing"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Crash reporting consent request"))
    }

    /// Secondary explanatory copy, extracted so the catalog key stays one
    /// translatable unit (it was previously two concatenated literals, which
    /// never localized at all).
    private var detailText: String {
        L10n.string(
            "Reports are stored locally and only shared when you choose to. No personal data leaves your Mac without your permission."
        )
    }
}
