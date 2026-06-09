import SwiftUI

// MARK: - CrashRecoveryBanner

/// Non-modal banner shown at launch when the previous session ended abnormally
/// (crash or force-quit).
///
/// Displayed as a `.safeAreaInset(edge: .top)` overlay in `BocanRootView` so
/// it never grabs keyboard focus, never triggers an NSAlert run-loop spin, and
/// therefore cannot cause an audio pop.
///
/// **Recover** — keeps the queue that was automatically restored from the
/// last periodic save and dismisses the banner.
///
/// **Start Fresh** — clears the queue and all persisted state, then dismisses
/// the banner so the next launch also starts clean.
struct CrashRecoveryBanner: View {
    @EnvironmentObject private var vm: LibraryViewModel
    @AppStorage("launch.didCrashPreviously") private var didCrashPreviously = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(localized: "Bòcan quit unexpectedly")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(self.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(L10n.string("Start Fresh")) {
                    Task { @MainActor in
                        await self.vm.clearQueue()
                        self.didCrashPreviously = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.string("Clear the restored queue and start with nothing queued."))
                .accessibilityLabel(L10n.string("Start with an empty queue"))

                Button(L10n.string("Recover")) {
                    self.didCrashPreviously = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(L10n.string("Keep the restored queue and continue where you left off."))
                .accessibilityLabel(L10n.string("Keep the restored queue"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Crash recovery banner"))
    }

    /// Explanatory copy under the headline, extracted so the catalog key fits
    /// the line-length limit at this indentation.
    private var detailText: String {
        L10n.string(
            "Your queue has been restored from the last auto-save. You can continue listening or start with a fresh queue."
        )
    }
}
