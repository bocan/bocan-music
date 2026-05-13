import SwiftUI

// MARK: - AboutView

public struct AboutView: View {
    private let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

    private let onCheckForUpdates: () -> Void
    private let canCheckForUpdates: Bool

    public init(onCheckForUpdates: @escaping () -> Void = {}, canCheckForUpdates: Bool = true) {
        self.onCheckForUpdates = onCheckForUpdates
        self.canCheckForUpdates = canCheckForUpdates
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("Bòcan")
                    .font(.title.bold())
                Text("Version \(self.version) (\(self.build))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("A thoughtful local music player for macOS.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Check for Updates\u{2026}") {
                self.onCheckForUpdates()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!self.canCheckForUpdates)
            .help("Check whether a newer version of Bòcan is available.")

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Third-Party Notices")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                NoticesHTMLView()
                    .frame(maxHeight: 160)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}
