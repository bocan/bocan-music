import SwiftUI

// MARK: - SubsonicOfflineBanner

/// Phase 19 step 17: inline banner shown above per-server Subsonic
/// destinations when the connection monitor reports the server is offline.
/// The "Retry now" button asks the connection monitor to re-ping
/// immediately so the user doesn't have to wait for the backoff schedule.
public struct SubsonicOfflineBanner: View {
    let serverID: UUID
    let state: SubsonicSidebarConnectionState
    let onRetry: () -> Void

    public init(
        serverID: UUID,
        state: SubsonicSidebarConnectionState,
        onRetry: @escaping () -> Void
    ) {
        self.serverID = serverID
        self.state = state
        self.onRetry = onRetry
    }

    public var body: some View {
        if self.state.isOffline {
            HStack(spacing: 10) {
                Image(systemName: self.iconName)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.headline)
                        .font(Typography.subheadline)
                    Text(self.state.displayLabel)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(L10n.string("Retry now")) {
                    self.onRetry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L10n.string("Retry connection now"))
                .help(L10n.string("Re-ping this server immediately, bypassing the backoff timer"))
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .overlay(
                Rectangle()
                    .fill(Color.orange.opacity(0.35))
                    .frame(height: 1),
                alignment: .bottom
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.string("\(self.headline): \(self.state.displayLabel)"))
        }
    }

    private var iconName: String {
        switch self.state {
        case .authFailed:
            "lock.trianglebadge.exclamationmark"

        case .serverError:
            "exclamationmark.octagon"

        default:
            "wifi.exclamationmark"
        }
    }

    private var headline: String {
        switch self.state {
        case .authFailed:
            L10n.string("Authentication failed")

        case .serverError:
            L10n.string("Server returned an error")

        default:
            L10n.string("Server unreachable")
        }
    }
}
