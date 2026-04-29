import SwiftUI

// MARK: - ConnectLastFmSheet

struct ConnectLastFmSheet: View {
    @ObservedObject var viewModel: ScrobbleSettingsViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Last.fm")
                .font(.title2.weight(.semibold))
            Text(
                "Bòcan will open last.fm in your browser to authorise this device. " +
                    "Once you approve, return here — your account will appear automatically."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if self.viewModel.isAuthenticatingLastFm {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser authorisation…")
                        .foregroundStyle(.secondary)
                }
            }
            if let err = viewModel.lastFmAuthError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) { self.isPresented = false }
                Spacer()
                Button(self.viewModel.lastFm.isConnected ? "Done" : "Open last.fm") {
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
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - ConnectListenBrainzSheet

struct ConnectListenBrainzSheet: View {
    @ObservedObject var viewModel: ScrobbleSettingsViewModel
    @Binding var isPresented: Bool
    @State private var token = ""
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect ListenBrainz")
                .font(.title2.weight(.semibold))
            Text(
                "Paste your ListenBrainz user token. You can find it on " +
                    "listenbrainz.org/profile/."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            SecureField("User token", text: self.$token)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("ListenBrainz user token")

            if let err = viewModel.listenBrainzTokenError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) { self.isPresented = false }
                Spacer()
                Button("Connect") {
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
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
