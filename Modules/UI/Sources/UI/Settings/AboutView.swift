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

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Third-Party Notices")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    Text(self.creditsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4)
                }
                .frame(maxHeight: 160)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }

    private var creditsText: String {
        guard let url = Bundle.main.url(forResource: "NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "See NOTICES.md for third-party licence information." }
        return text
    }
}
