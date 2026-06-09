import Scrobble
import SwiftUI

// MARK: - ScrobbleSettingsView

/// Settings pane for the two scrobble providers. Renders connection status,
/// queue stats, dead-letter actions, and a button to launch `ConnectSheet`.
public struct ScrobbleSettingsView: View {
    @ObservedObject var viewModel: ScrobbleSettingsViewModel
    @State private var showLastFmSheet = false
    @State private var showListenBrainzSheet = false
    @State private var showRockskySheet = false
    @State private var showRecentSheet = false

    public init(viewModel: ScrobbleSettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section(L10n.string("Last.fm")) {
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
            Section(L10n.string("ListenBrainz")) {
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
            Section(L10n.string("Rocksky")) {
                self.providerRow(
                    status: self.viewModel.rocksky,
                    connectAction: { self.showRockskySheet = true },
                    disconnectAction: { Task { await self.viewModel.disconnectRocksky() } }
                )
                if let err = viewModel.rockskyConnectError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if let stats = viewModel.stats {
                Section(L10n.string("Queue")) {
                    LabeledContent(L10n.string("Pending"), value: String(stats.pending))
                        .accessibilityHint(L10n.string("Number of scrobbles waiting to be submitted"))
                    LabeledContent(L10n.string("Failed (dead)"), value: String(stats.dead))
                        .accessibilityHint(L10n.string("Scrobbles that have exhausted all retry attempts"))
                    LabeledContent(L10n.string("Sent today"), value: String(stats.submittedToday))
                        .accessibilityHint(L10n.string("Scrobbles successfully submitted in the last 24 hours"))
                    if stats.dead > 0 {
                        HStack {
                            Button(L10n.string("Retry failed")) {
                                Task { await self.viewModel.resubmitDeadLetters() }
                            }
                            .help(L10n.string("Re-queue all dead scrobbles and attempt immediate resubmission"))
                            Button(L10n.string("Discard failed"), role: .destructive) {
                                Task { await self.viewModel.purgeDeadLetters() }
                            }
                            .help(L10n.string("Permanently delete all failed scrobbles from the queue"))
                        }
                    }
                    Button(L10n.string("Recent Scrobbles…")) {
                        self.showRecentSheet = true
                    }
                    .help(L10n.string("View the last 50 scrobbled tracks and their submission status"))
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
        .sheet(isPresented: self.$showRockskySheet) {
            ConnectRockskySheet(viewModel: self.viewModel, isPresented: self.$showRockskySheet)
        }
        .sheet(isPresented: self.$showRecentSheet) {
            RecentScrobblesView(viewModel: self.viewModel)
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
                if status.isConnected {
                    if let user = status.username {
                        Text(localized: "Connected as \(user)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(localized: "Connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(localized: "Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status.isConnected {
                Button(L10n.string("Disconnect"), role: .destructive, action: disconnectAction)
                    .help(L10n.string("Disconnect \(status.displayName) and remove stored credentials"))
            } else {
                Button(L10n.string("Connect…"), action: connectAction)
                    .help(L10n.string("Connect your \(status.displayName) account"))
            }
        }
    }
}
