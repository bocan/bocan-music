import SwiftUI
import WebKit

// MARK: - NoticesHTMLView

/// Renders NOTICES.md from the app bundle as formatted HTML in a WebView.
/// Handles its own scrolling. Works embedded (e.g. About) or full-screen.
public struct NoticesHTMLView: View {
    @State private var html = ""

    public init() {}

    public var body: some View {
        _NoticesWebView(html: self.html)
            .onAppear(perform: self.loadContent)
    }

    // MARK: - Private

    private func loadContent() {
        guard
            let url = Bundle.main.url(forResource: "NOTICES", withExtension: "md"),
            let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        self.html = NoticesRenderer.html(from: raw)
    }
}

// MARK: - _NoticesWebView

/// NSViewRepresentable wrapping WKWebView because SwiftUI has no equivalent
/// that can render arbitrary HTML with inline CSS and dark-mode media queries.
private struct _NoticesWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard !self.html.isEmpty else { return }
        webView.loadHTMLString(self.html, baseURL: nil)
    }
}

// MARK: - NoticesRenderer

enum NoticesRenderer {
    // swiftlint:disable:next function_body_length
    static func html(from markdown: String) -> String {
        let css = """
        body {
           font-family: -apple-system, BlinkMacSystemFont, sans-serif;
           font-size: 13px; line-height: 1.6;
           color: #1d1d1f; background: transparent;
           margin: 0; padding: 24px 28px;
        }
        @media (prefers-color-scheme: dark) {
           body { color: #f5f5f7; }
           a { color: #2997ff; }
           code { background: rgba(255,255,255,0.1); }
           h2, h3 { border-bottom-color: rgba(255,255,255,0.15); }
        }
        h1 { font-size: 20px; font-weight: 700; margin: 0 0 16px; }
        h2 {
           font-size: 14px; font-weight: 600; margin: 24px 0 6px;
           border-bottom: 1px solid rgba(0,0,0,0.12); padding-bottom: 4px;
        }
        h3 { font-size: 13px; font-weight: 600; margin: 16px 0 4px; }
        p { margin: 4px 0; }
        a { color: #0066cc; text-decoration: none; }
        a:hover { text-decoration: underline; }
        hr { border: none; border-top: 1px solid rgba(128,128,128,0.3); margin: 20px 0; }
        code {
           font-family: 'SF Mono', Menlo, monospace; font-size: 11px;
           background: rgba(0,0,0,0.06); padding: 1px 4px; border-radius: 3px;
        }
        strong { font-weight: 600; }
        em { font-style: italic; }
        """

        var body = ""
        var paraLines = [String]()

        func flush() {
            let text = paraLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { body += "<p>\(text)</p>\n" }
            paraLines.removeAll()
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("### ") {
                flush()
                body += "<h3>\(self.inline(String(line.dropFirst(4))))</h3>\n"
            } else if line.hasPrefix("## ") {
                flush()
                body += "<h2>\(self.inline(String(line.dropFirst(3))))</h2>\n"
            } else if line.hasPrefix("# ") {
                flush()
                body += "<h1>\(self.inline(String(line.dropFirst(2))))</h1>\n"
            } else if line == "---" {
                flush()
                body += "<hr>\n"
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paraLines.append(self.inline(line))
            }
        }
        flush()

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="UTF-8"><style>\(css)</style></head>
        <body>\(body)</body>
        </html>
        """
    }

    private static func inline(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // Angle-bracket URLs: &lt;https://...&gt;
        s = s.replacingOccurrences(
            of: "&lt;(https?://[^&\\s]+)&gt;",
            with: "<a href=\"$1\">$1</a>",
            options: .regularExpression
        )
        // Markdown links: [text](url)
        s = s.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)",
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )
        // Bold: **text**
        s = s.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*",
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        // Italic: *text*
        s = s.replacingOccurrences(
            of: "(?<![*])\\*([^*]+)\\*(?![*])",
            with: "<em>$1</em>",
            options: .regularExpression
        )
        // Inline code: `code`
        s = s.replacingOccurrences(
            of: "`([^`]+)`",
            with: "<code>$1</code>",
            options: .regularExpression
        )
        return s
    }
}
