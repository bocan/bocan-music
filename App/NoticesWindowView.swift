import SwiftUI

// MARK: - NoticesWindowView

/// Scrollable view of third-party open-source licence notices.
struct NoticesWindowView: View {
    @State private var content = AttributedString("")

    var body: some View {
        ScrollView {
            Text(self.content)
                .textSelection(.enabled)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: self.loadContent)
    }

    // MARK: - Private

    private func loadContent() {
        guard
            let url = Bundle.main.url(forResource: "NOTICES", withExtension: "md"),
            let raw = try? String(contentsOf: url, encoding: .utf8) else { return }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        self.content = (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }
}
