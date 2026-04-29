import Scrobble
import SwiftUI

// MARK: - ScrobbleSettingsView

/// Settings pane for the two scrobble providers. Renders connection status,
/// queue stats, dead-letter actions, and a button to launch `ConnectSheet`.
public struct ScrobbleSettingsView: View {
    @ObservedObject var viewModel: ScrobbleSettingsViewModel
    @State private var showLastFmSheet = false
    @State private var showListenBrainzSheet = false

    public init(viewModel: ScrobbleSettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("Last.fm") {
                self.providerRow(
                    status: self.viewModel.lastFm,
                    connectAction: { self.showLastFmSheet = true },
                    disconnectAction: { Task { await self.viewModel.disconnectLastFm() } }
                )
                if let err = viewModel.lastFmAuthError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("ListenBrainz") {
                self.providerRow(
                    status: self.viewModel.listenBrainz,
                    connectAction: { self.showListenBrainzSheet = true },
                    disconnectAction: { Task { await self.viewModel.disconnectListenBrainz() } }
                )
                if let err = viewModel.listenBrainzTokenError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if let stats = viewModel.stats {
                Section("Queue") {
                    LabeledContent("Pending", value: "\(stats.pending)")
                    LabeledContent("Failed (dead)", value: "\(stats.dead)")
                    LabeledContent("Sent today", value: "\(stats.submittedToday)")
                    if stats.dead > 0 {
                        HStack {
                            Button("Retry failed") {
                                Task { await self.viewModel.resubmitDeadLetters() }
                            }
                            Button("Discard failed", role: .destructive) {
                                Task { await self.viewModel.purgeDeadLetters() }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { self.viewModel.appear() }
        .onDisappear { self.viewModel.disappear() }
        .sheet(isPresented: self.$showLastFmSheet) {
            ConnectLastFmSheet(viewModel: self.viewModel, isPresented: self.$showLastFmSheet)
        }
        .sheet(isPresented: self.$showListenBrainzSheet) {
            ConnectListenBrainzSheet(viewModel: self.viewModel, isPresented: self.$showListenBrainzSheet)
        }
        .accessibilityIdentifier("scrobble-settings")
    }

    private func providerRow(
        status: ScrobbleSettingsViewModel.ProviderStatus,
        connectAction: @escaping () -> Void,
        disconnectAction: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayName)
                    .font(.headline)
                if status.isConnected, let user = status.username {
                    Text("Connected as \(user)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status.isConnected {
                Button("Disconnect", role: .destructive, action: disconnectAction)
            } else {
                Button("Connect…", action: connectAction)
            }
        }
    }
}
