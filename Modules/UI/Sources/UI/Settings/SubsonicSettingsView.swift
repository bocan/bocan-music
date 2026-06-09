import AppKit
import Subsonic
import SwiftUI

// MARK: - SubsonicSettingsView

/// Phase 19 step 12: Settings → Sources tab.
///
/// Two-pane layout:
/// - Left: scrollable list of configured servers with status dots and
///   reorder/context-menu affordances.
/// - Right: inline editor for the selected (or newly-added) server, with
///   `Test Connection` surfacing a capability list on success.
public struct SubsonicSettingsView: View {
    @ObservedObject private var vm: SubsonicSettingsViewModel

    public init(viewModel: SubsonicSettingsViewModel) {
        self.vm = viewModel
    }

    public var body: some View {
        HStack(spacing: 0) {
            self.sidebar
                .frame(width: 240)

            Divider()

            self.detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await self.vm.reload() }
        .navigationTitle(L10n.string("Sources"))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding<UUID?>(
                get: { self.vm.selectedServerID },
                set: { newValue in
                    if let id = newValue { Task { await self.vm.selectServer(id) } }
                }
            )) {
                ForEach(self.vm.servers, id: \.id) { server in
                    SubsonicServerRow(
                        server: server,
                        status: self.vm.statuses[server.id] ?? .unknown
                    )
                    .tag(server.id)
                    .contextMenu {
                        Button(L10n.string("Edit")) {
                            Task { await self.vm.selectServer(server.id) }
                        }
                        .accessibilityLabel(L10n.string("Edit \(server.name)"))
                        Button(L10n.string("Reveal Credential in Keychain")) {
                            Self.revealInKeychain()
                        }
                        .accessibilityLabel(L10n.string("Reveal \(server.name) credential in Keychain Access"))
                        Divider()
                        Button(L10n.string("Remove"), role: .destructive) {
                            Task {
                                await self.vm.selectServer(server.id)
                                await self.vm.deleteSelected()
                            }
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
                .help(L10n.string("Add a new Subsonic-compatible server"))
                .accessibilityLabel(L10n.string("Add new source server"))

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

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if self.vm.servers.isEmpty, self.vm.editor.id == nil, self.vm.editor.name.isEmpty {
            SubsonicEmptyState { self.vm.beginAddServer() }
        } else {
            SubsonicServerEditorView(vm: self.vm)
        }
    }

    // MARK: - Keychain reveal

    /// Opens the user's Keychain Access app. We can't deep-link to a specific
    /// item from a sandboxed app, but launching Keychain Access lets the user
    /// search for `io.cloudcauldron.bocan.subsonic`.
    static func revealInKeychain() {
        let path = "/System/Applications/Utilities/Keychain Access.app"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - Server row

private struct SubsonicServerRow: View {
    let server: SubsonicServer
    let status: SubsonicConnectionStatus

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

private struct SubsonicEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(localized: "No Sources Configured")
                .font(.title3)
            Text(localized: "Add a Subsonic, Navidrome, or other compatible server to stream your remote music library.")
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Editor

private struct SubsonicServerEditorView: View {
    @ObservedObject var vm: SubsonicSettingsViewModel

    var body: some View {
        Form {
            Section(L10n.string("Identity")) {
                TextField(L10n.string("Display Name"), text: self.$vm.editor.name)
                TextField(
                    L10n.string("Server URL"),
                    text: self.$vm.editor.serverURLText,
                    prompt: Text(verbatim: "https://music.example.com")
                )
                .textContentType(.URL)
                .autocorrectionDisabled(true)
                if let problem = self.vm.editor.firstValidationError,
                   problem.contains("URL") {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.string("Authentication")) {
                Picker(L10n.string("Method"), selection: self.$vm.editor.authKind) {
                    Text(localized: "Token + Password (Subsonic / Navidrome)")
                        .tag(SubsonicAuthKind.tokenSalt)
                    Text(localized: "API Key (OpenSubsonic)")
                        .tag(SubsonicAuthKind.apiKey)
                }
                .pickerStyle(.menu)
                if self.vm.editor.authKind == .tokenSalt {
                    TextField(L10n.string("Username"), text: self.$vm.editor.username)
                        .autocorrectionDisabled(true)
                    SecureField(L10n.string("Password"), text: self.$vm.editor.secret)
                } else {
                    SecureField(L10n.string("API Key"), text: self.$vm.editor.secret)
                }
            }

            Section(L10n.string("Security")) {
                Toggle(L10n.string("Allow self-signed TLS certificate"), isOn: self.$vm.editor.allowSelfSignedTLS)
                if self.vm.editor.allowSelfSignedTLS {
                    Label(
                        self.selfSignedWarning,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section(L10n.string("Streaming")) {
                Picker(L10n.string("Maximum Bitrate"), selection: self.$vm.editor.bitrateKind) {
                    Text(localized: "Original quality").tag(SubsonicSettingsViewModel.BitrateKind.original)
                    Text(localized: "Cap at…").tag(SubsonicSettingsViewModel.BitrateKind.kbps)
                }
                .pickerStyle(.segmented)

                if self.vm.editor.bitrateKind == .kbps {
                    Picker(L10n.string("Bitrate"), selection: self.$vm.editor.bitrateKbps) {
                        ForEach([96, 128, 192, 256, 320], id: \.self) { kbps in
                            Text(localized: "\(kbps) kbps").tag(kbps)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Picker(L10n.string("Preferred Format"), selection: self.$vm.editor.preferredFormat) {
                    ForEach(SubsonicStreamFormat.allCases, id: \.self) { fmt in
                        Text(self.label(for: fmt)).tag(fmt)
                    }
                }
                .pickerStyle(.menu)

                Toggle(L10n.string("Pre-cache the next track"), isOn: self.$vm.editor.precacheNext)
            }

            Section(L10n.string("Integration")) {
                Toggle(L10n.string("Include in global search"), isOn: self.$vm.editor.includeInGlobalSearch)
                Toggle(L10n.string("Show in sidebar"), isOn: self.$vm.editor.showInSidebar)
                Toggle(L10n.string("Scrobble to this server"), isOn: self.$vm.editor.scrobble)
                Toggle(L10n.string("Sync starred items"), isOn: self.$vm.editor.syncStars)
                Toggle(L10n.string("Sync star ratings"), isOn: self.$vm.editor.syncRatings)
            }

            if let test = self.vm.lastTestResult {
                Section(L10n.string("Last Test")) {
                    TestResultBlock(result: test)
                }
            }

            if let err = self.vm.errorMessage {
                Section {
                    Label(err, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Button(L10n.string("Test Connection")) {
                        Task { await self.vm.testCurrentEditor() }
                    }
                    .disabled(self.vm.isTesting)
                    .help(L10n.string("Ping this server and report its capabilities"))
                    .accessibilityLabel(L10n.string("Test connection to this server"))

                    Spacer()

                    if self.vm.editor.id != nil {
                        Button(L10n.string("Delete"), role: .destructive) {
                            Task { await self.vm.deleteSelected() }
                        }
                        .help(L10n.string("Remove this server and its Keychain credential"))
                        .accessibilityLabel(L10n.string("Delete this server"))
                    }

                    Button(L10n.string("Save")) {
                        Task { await self.vm.save() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.vm.editor.firstValidationError != nil)
                    .help(L10n.string("Save changes to this server (\u{2318}\u{21A9})"))
                    .accessibilityLabel(L10n.string("Save server settings"))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Warning shown when self-signed TLS is allowed. Two sentence keys joined
    /// in code so each stays within the line limit (#314).
    private var selfSignedWarning: String {
        L10n.string("Allowing self-signed certificates means Bòcan cannot verify that the server is who it claims to be.")
            + " " + L10n.string("Use only on a network you control.")
    }

    private func label(for format: SubsonicStreamFormat) -> String {
        switch format {
        case .original:
            L10n.string("Original (no transcode)")

        case .mp3:
            "MP3"

        case .opus:
            "Opus"

        case .aac:
            "AAC"

        case .flac:
            "FLAC"
        }
    }
}

// MARK: - Test result block

private struct TestResultBlock: View {
    let result: SubsonicSettingsViewModel.TestResult

    var body: some View {
        if self.result.success, let caps = self.result.capabilities {
            VStack(alignment: .leading, spacing: 4) {
                Label(self.headline(for: caps), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if !self.extensions(from: caps).isEmpty {
                    Text(localized: "Advertised extensions: \(self.extensions(from: caps).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Label(self.result.message ?? L10n.string("Connection failed."), systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func headline(for caps: SubsonicCapabilities) -> String {
        let kind = caps.serverType?.capitalized ?? L10n.string("Subsonic-compatible server")
        let version = caps.serverVersion.map { " \($0)" } ?? ""
        let api = caps.apiVersion.map { " (API \($0))" } ?? ""
        return "\(kind)\(version)\(api)"
    }

    private func extensions(from caps: SubsonicCapabilities) -> [String] {
        var names: [String] = []
        if caps.isOpenSubsonic { names.append("openSubsonic") }
        if caps.supportsApiKey { names.append("apiKeyAuthentication") }
        if caps.supportsLyricsBySongId { names.append("songLyrics") }
        if caps.supportsPodcasts { names.append("podcasts") }
        if caps.supportsInternetRadio { names.append("internetRadio") }
        if caps.supportsBookmarks { names.append("bookmarks") }
        if caps.supportsJukebox { names.append("jukebox") }
        if caps.supportsShares { names.append("shares") }
        if caps.supportsRandomSongsByGenre { names.append("randomSongsByGenre") }
        return names
    }
}
