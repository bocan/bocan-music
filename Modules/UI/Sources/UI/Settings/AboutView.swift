import SwiftUI

// MARK: - AboutView

public struct AboutView: View {
    private let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

    public init() {}

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

            Text("A thoughtful music player for macOS.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 300)
        .navigationTitle("About")
    }
}
