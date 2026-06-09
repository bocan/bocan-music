import SwiftUI

// MARK: - ConnectLastFmSheet

struct ConnectLastFmSheet: View {
    @ObservedObject var viewModel: ScrobbleSettingsViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized: "Connect Last.fm")
                .font(.title2.weight(.semibold))
            Text(
                L10n.string("Bòcan will open last.fm in your browser to authorise this device.")
                    + " " + L10n.string("Once you approve, return here — your account will appear automatically.")
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if self.viewModel.isAuthenticatingLastFm {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.string("Waiting for Last.fm authorisation"))
                    Text(localized: "Waiting for browser authorisation…")
                        .foregroundStyle(.secondary)
                }
            }
            if let err = viewModel.lastFmAuthError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(L10n.string("Cancel"), role: .cancel) { self.isPresented = false }
                    .help(L10n.string("Cancel the Last.fm connection flow"))
                Spacer()
                Button(self.viewModel.lastFm.isConnected ? L10n.string("Done") : L10n.string("Open last.fm")) {
                    if self.viewModel.lastFm.isConnected {
                        self.isPresented = false
                    } else {
                        Task {
                            await self.viewModel.connectLastFm()
                            if self.viewModel.lastFm.isConnected {
                                self.isPresented = false
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(self.viewModel.isAuthenticatingLastFm)
                .help(self.viewModel.lastFm.isConnected
                    ? L10n.string("Close this sheet")
                    : L10n.string("Open last.fm in your browser to authorise Bòcan"))
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - ConnectRockskySheet

struct ConnectRockskySheet: View {
    @ObservedObject var viewModel: ScrobbleSettingsViewModel
    @Binding var isPresented: Bool
    @State private var apiKey = ""
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized: "Connect Rocksky")
                .font(.title2.weight(.semibold))
            Text(
                L10n.string("Enter your API key from your Rocksky account settings at rocksky.app/apikeys.")
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            LabeledContent(L10n.string("API Key")) {
                SecureField(L10n.string("API key"), text: self.$apiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.string("Rocksky API key"))
            }

            if let err = viewModel.rockskyConnectError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(L10n.string("Cancel"), role: .cancel) { self.isPresented = false }
                    .help(L10n.string("Cancel the Rocksky connection"))
                Spacer()
                Button(L10n.string("Connect")) {
                    self.submitting = true
                    Task {
                        await self.viewModel.connectRocksky(apiKey: self.apiKey)
                        self.submitting = false
                        if self.viewModel.rocksky.isConnected {
                            self.isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(self.apiKey.isEmpty || self.submitting)
                .help(L10n.string("Save your Rocksky API key and connect your account"))
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct ConnectListenBrainzSheet: View {
    @ObservedObject var viewModel: ScrobbleSettingsViewModel
    @Binding var isPresented: Bool
    @State private var token = ""
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized: "Connect ListenBrainz")
                .font(.title2.weight(.semibold))
            Text(
                L10n.string("Paste your ListenBrainz user token. You can find it on listenbrainz.org/profile/.")
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            SecureField(L10n.string("User token"), text: self.$token)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.string("ListenBrainz user token"))

            if let err = viewModel.listenBrainzTokenError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(L10n.string("Cancel"), role: .cancel) { self.isPresented = false }
                    .help(L10n.string("Cancel the ListenBrainz connection flow"))
                Spacer()
                Button(L10n.string("Connect")) {
                    self.submitting = true
                    Task {
                        await self.viewModel.connectListenBrainz(token: self.token)
                        self.submitting = false
                        if self.viewModel.listenBrainz.isConnected {
                            self.isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(self.token.isEmpty || self.submitting)
                .help(L10n.string("Submit your ListenBrainz token and connect your account"))
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
