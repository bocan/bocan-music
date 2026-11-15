import Jellyfin
import SwiftUI

// MARK: - JellyfinSettingsView

/// ADR-097, slice 3: Settings, Sources, Jellyfin.
///
/// Two panes, like the Subsonic page: a server list on the left, and on the
/// right the editor for the selected server or for a new one. A new server is
/// saved by signing in, with a password or with Quick Connect.
public struct JellyfinSettingsView: View {
    @ObservedObject private var vm: JellyfinSettingsViewModel

    public init(viewModel: JellyfinSettingsViewModel) {
        self.vm = viewModel
    }

    public var body: some View {
        Group {
            if self.isTrulyEmpty {
                JellyfinEmptyState { self.vm.beginAddServer() }
            } else {
                HStack(spacing: 0) {
                    self.sidebar
                        .frame(width: 240)
                    Divider()
                    JellyfinServerEditorView(vm: self.vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await self.vm.reload() }
    }

    /// Nothing to list and no draft in progress.
    private var isTrulyEmpty: Bool {
        self.vm.servers.isEmpty && !self.vm.isAddingNew
    }

    // MARK: - Server list

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding<UUID?>(
                get: { self.vm.selectedServerID },
                set: { newValue in
                    if let id = newValue {
                        self.vm.selectServer(id)
                    }
                }
            )) {
                ForEach(self.vm.servers, id: \.id) { server in
                    JellyfinServerRow(server: server, status: self.vm.statuses[server.id] ?? .unknown)
                        .tag(server.id)
                        .contextMenu {
                            Button(L10n.string("Edit")) { self.vm.selectServer(server.id) }
                                .accessibilityLabel(L10n.string("Edit \(server.name)"))
                            Divider()
                            Button(L10n.string("Remove"), role: .destructive) {
                                self.vm.selectServer(server.id)
                                Task { await self.vm.deleteSelected() }
                            }
                            .accessibilityLabel(L10n.string("Remove \(server.name)"))
                        }
                }
            }

            Divider()

            HStack {
                Button {
                    self.vm.beginAddServer()
                } label: {
                    Label(L10n.string("Add Server"), systemImage: "plus")
                }
                .help(L10n.string("Add a new Jellyfin server"))
                .accessibilityLabel(L10n.string("Add new Jellyfin server"))

                Spacer()

                Button(L10n.string("Test All")) {
                    Task { await self.vm.testAllConnections() }
                }
                .disabled(self.vm.servers.isEmpty || self.vm.isTesting)
                .help(L10n.string("Ping every configured server"))
                .accessibilityLabel(L10n.string("Test all configured source connections"))
            }
            .padding(8)
        }
    }
}

// MARK: - Server row

private struct JellyfinServerRow: View {
    let server: JellyfinServer
    let status: JellyfinConnectionStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(self.statusColor)
                .frame(width: 8, height: 8)
                .help(self.status.localizedDescription)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.server.name)
                    .font(.body)
                Text(self.server.serverURL.host ?? self.server.serverURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.string("\(self.server.name), \(self.server.serverURL.host ?? self.server.serverURL.absoluteString)")
        )
        .accessibilityValue(self.status.localizedDescription)
    }

    private var statusColor: Color {
        switch self.status {
        case .online:
            .green

        case .connecting:
            .yellow

        case .authFailed:
            .orange

        case .unreachable, .serverError:
            .red

        case .unknown:
            .secondary
        }
    }
}

// MARK: - Empty state

private struct JellyfinEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(localized: "No Jellyfin Servers")
                .font(.title3)
            Text(localized: "Add a Jellyfin server to stream your music from it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button {
                self.onAdd()
            } label: {
                Label(L10n.string("Add Server"), systemImage: "plus")
            }
            .keyboardShortcut(.defaultAction)
            .help(L10n.string("Adds a Jellyfin server. You can add more than one and browse them side by side."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
