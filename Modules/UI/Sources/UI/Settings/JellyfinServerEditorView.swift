import Jellyfin
import SwiftUI

// MARK: - JellyfinServerEditorView

/// The right-hand pane of Settings, Sources, Jellyfin: the form for one server.
struct JellyfinServerEditorView: View {
    @ObservedObject var vm: JellyfinSettingsViewModel

    /// A server that is not saved yet, or one whose token the server refused,
    /// shows the sign-in section.
    private var showsSignIn: Bool {
        self.vm.editor.id == nil || self.vm.needsSignIn
    }

    var body: some View {
        Form {
            self.serverSection
            self.securitySection
            if self.showsSignIn {
                self.signInSection
            } else if let account = self.vm.editor.signedInAs {
                Section(L10n.string("Account")) {
                    LabeledContent(L10n.string("Signed in as"), value: account)
                }
            }
            self.streamingSection
            self.integrationSection
            if let test = self.vm.lastTestResult {
                Section(L10n.string("Last Test")) {
                    JellyfinTestResultBlock(result: test)
                }
            }
            if let message = self.vm.errorMessage {
                Section {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
            self.actionsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section(L10n.string("Server")) {
            TextField(L10n.string("Display Name"), text: self.$vm.editor.name)
            TextField(
                L10n.string("Server URL"),
                text: self.$vm.editor.serverURLText,
                prompt: Text(verbatim: "https://jellyfin.example.com")
            )
            .textContentType(.URL)
            .autocorrectionDisabled(true)
            Button(L10n.string("Test Server")) {
                Task { await self.vm.testServer() }
            }
            .disabled(self.vm.isTesting || self.vm.editor.addressProblem != nil)
            .help(L10n.string("Ask the server for its name and version. It needs no sign-in."))
            .accessibilityLabel(L10n.string("Test the connection to this server"))
        }
    }

    private var securitySection: some View {
        Section(L10n.string("Security")) {
            Toggle(L10n.string("Allow self-signed TLS certificate"), isOn: self.$vm.editor.allowSelfSignedTLS)
                .help(L10n.string(
                    "For a server whose certificate you issued yourself. It drops the check that you reached the right machine."
                ))
            if self.vm.editor.allowSelfSignedTLS {
                Label(self.selfSignedWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var signInSection: some View {
        Section(self.vm.editor.id == nil ? L10n.string("Sign In") : L10n.string("Sign In Again")) {
            if self.vm.editor.id != nil {
                Text(localized: "The server no longer accepts the saved sign-in. Sign in again to keep using it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(L10n.string("User name"), text: self.$vm.editor.username)
                .autocorrectionDisabled(true)
            SecureField(L10n.string("Password"), text: self.$vm.editor.password)
            Text(localized: "Bòcan does not keep the password. It keeps a sign-in token in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(L10n.string("Sign In")) {
                    Task { await self.vm.signInWithPassword() }
                }
                .disabled(self.vm.isSigningIn || self.vm.editor.signInProblem() != nil)
                .keyboardShortcut(self.vm.editor.id == nil ? .defaultAction : nil)
                .help(L10n.string("Sign in with this user name and password and add the server."))
                .accessibilityLabel(L10n.string("Sign in to this server"))

                Button(L10n.string("Use Quick Connect")) {
                    self.vm.startQuickConnect()
                }
                .disabled(self.vm.isSigningIn || self.vm.editor.addressProblem != nil)
                .help(L10n.string("Sign in without a password. You approve a code in a Jellyfin app where you are already signed in."))
                .accessibilityLabel(L10n.string("Sign in with Quick Connect"))
            }
            if let code = self.vm.quickConnectCode {
                self.quickConnectBlock(code: code)
            }
        }
    }

    private func quickConnectBlock(code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(code)
                .font(.system(.title, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
                .accessibilityLabel(L10n.string("Quick Connect code \(code)"))
            Text(localized: "In a Jellyfin app where you are signed in, open Quick Connect and enter this code. This page waits for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.string("Cancel")) {
                self.vm.cancelQuickConnect()
            }
            .help(L10n.string("Stop waiting for the code to be approved."))
            .accessibilityLabel(L10n.string("Cancel Quick Connect"))
        }
    }

    private var streamingSection: some View {
        Section(L10n.string("Streaming")) {
            Picker(L10n.string("Preferred Format"), selection: self.$vm.editor.preferredFormat) {
                ForEach(JellyfinStreamFormat.allCases, id: \.self) { format in
                    Text(self.label(for: format)).tag(format)
                }
            }
            .pickerStyle(.menu)
            .help(L10n.string("The format to ask for. Original plays the file as the server stores it, with no conversion."))

            Picker(L10n.string("Maximum Bitrate"), selection: self.$vm.editor.bitrateKind) {
                Text(localized: "No limit").tag(JellyfinSettingsViewModel.BitrateKind.original)
                Text(localized: "Cap at\u{2026}").tag(JellyfinSettingsViewModel.BitrateKind.kbps)
            }
            .pickerStyle(.segmented)
            .disabled(!self.vm.editor.isBitrateEnabled)
            .help(L10n.string("Asks the server to convert down to this ceiling. It needs a format other than Original."))

            if self.vm.editor.bitrateKind == .kbps {
                Picker(L10n.string("Bitrate"), selection: self.$vm.editor.bitrateKbps) {
                    ForEach([96, 128, 192, 256, 320], id: \.self) { kbps in
                        Text(localized: "\(kbps) kbps").tag(kbps)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!self.vm.editor.isBitrateEnabled)
                .help(L10n.string("The ceiling the server converts to. Lower values use less of your connection on the move."))
            }
            if !self.vm.editor.isBitrateEnabled {
                Text(localized: "The bitrate limit applies only when a format other than Original is chosen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(L10n.string("Pre-cache the next track"), isOn: self.$vm.editor.precacheNext)
                .help(L10n.string(
                    "Fetches the next track in the queue while the current one plays, so a slow connection cannot cause a gap."
                ))
        }
    }

    private var integrationSection: some View {
        Section(L10n.string("Integration")) {
            Toggle(L10n.string("Include in global search"), isOn: self.$vm.editor.includeInGlobalSearch)
                .help(L10n.string("Lets this server answer the search field, so its music appears alongside your local results."))
            Toggle(L10n.string("Show in sidebar"), isOn: self.$vm.editor.showInSidebar)
                .help(L10n.string("Lists this server in the sidebar. Switch it off to keep the server configured but out of the way."))
            Toggle(L10n.string("Scrobble to this server"), isOn: self.$vm.editor.scrobble)
                .help(L10n.string(
                    "Reports finished plays to this server's own listening history, as well as to any scrobbling service you use."
                ))
            Toggle(L10n.string("Sync starred items"), isOn: self.$vm.editor.syncStars)
                .help(L10n
                    .string(
                        "Sends the stars you set here to the server as favourites. With it off, a star is not sent and is lost on quit."
                    ))
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if self.vm.editor.id != nil {
            Section {
                HStack {
                    Button(L10n.string("Remove"), role: .destructive) {
                        Task { await self.vm.deleteSelected() }
                    }
                    .help(L10n.string("Remove this server and its saved sign-in. The server is asked to end the sign-in too."))
                    .accessibilityLabel(L10n.string("Remove this server"))

                    Spacer()

                    Button(L10n.string("Save")) {
                        Task { await self.vm.save() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.vm.editor.saveProblem() != nil)
                    .help(L10n.string("Save changes to this server (\u{2318}\u{21A9})"))
                    .accessibilityLabel(L10n.string("Save server settings"))
                }
            }
        }
    }

    // MARK: - Text

    /// Two sentence keys joined in code so each stays within the line limit (#314).
    private var selfSignedWarning: String {
        L10n.string("Allowing self-signed certificates means Bòcan cannot verify that the server is who it claims to be.")
            + " " + L10n.string("Use only on a network you control.")
    }

    private func label(for format: JellyfinStreamFormat) -> String {
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

private struct JellyfinTestResultBlock: View {
    let result: JellyfinSettingsViewModel.TestResult

    var body: some View {
        if self.result.success {
            VStack(alignment: .leading, spacing: 4) {
                Label(self.headline, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(self.result.quickConnectAvailable
                    ? L10n.string("Quick Connect is on.")
                    : L10n.string("Quick Connect is off on this server."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if self.result.signedIn == false {
                    Label(
                        L10n.string("The server does not accept the saved sign-in."),
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        } else {
            Label(self.result.message ?? L10n.string("Connection failed."), systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var headline: String {
        let name = self.result.serverName ?? L10n.string("Jellyfin server")
        guard let version = self.result.version else { return name }
        return L10n.string("\(name), Jellyfin \(version)")
    }
}
