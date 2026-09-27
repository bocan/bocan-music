import Foundation
import Testing

// MARK: - AppKitTestIsolationConventionTests

/// A UI test that touches AppKit runs on the main actor. Swift Testing runs a
/// suite without `@MainActor` on the cooperative pool, and AppKit off the
/// main thread can deadlock the whole test process: the first `NSFont` use
/// runs `+[NSFont initialize]`, which waits for the main queue, while a
/// main-thread test creating an `NSWindow` waits for that initialiser. That
/// was the intermittent hang in CI's "Test UI package" step
/// (`TransportTimeLabelTests`, 2026-09-27).
///
/// A source convention: a test file that calls one of the AppKit APIs below,
/// outside comments and string literals, must say `@MainActor` somewhere. Per
/// file, not per suite, so it is a tripwire rather than a proof.
@Suite("AppKit use in UI tests is on the main actor")
struct AppKitTestIsolationConventionTests {
    /// Calls that load AppKit classes whose first use can wait on the main thread.
    private static let appKitCalls = [
        "NSFont.",
        "NSWindow(",
        "NSHostingView(",
        "NSHostingController(",
        "NSImage(",
        ".size(withAttributes:",
    ]

    private static var testsRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
    }

    /// `source` without `//` comments and single-line string literals, so a
    /// test that only names an API (a doc comment, a source-scan pattern)
    /// does not count as calling it.
    static func code(of source: String) -> String {
        var lines: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(Self.codeOnLine(line))
        }
        return lines.joined(separator: "\n")
    }

    /// One line of `code(of:)`: the characters outside a `//` comment and
    /// outside double quotes.
    private static func codeOnLine(_ line: Substring) -> String {
        var out = ""
        var inString = false
        var previous: Character = " "
        for char in line {
            if !inString, char == "/", previous == "/" {
                out.removeLast()
                break
            }
            if char == "\"", previous != "\\" {
                inString.toggle()
            } else if !inString {
                out.append(char)
            }
            previous = char
        }
        return out
    }

    @Test("every UI test file that calls AppKit is @MainActor")
    func appKitTestsAreMainActor() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.testsRoot, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        // This file is skipped: its sample source sits in a multi-line
        // literal, which `code(of:)` does not strip.
        let selfName = URL(filePath: #filePath).lastPathComponent
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != selfName {
            let source = try String(contentsOf: url, encoding: .utf8)
            let code = Self.code(of: source)
            let callsAppKit = Self.appKitCalls.contains { code.contains($0) }
            if callsAppKit, !code.contains("@MainActor") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "AppKit off the main actor can deadlock the UI suite: \(offenders.sorted())")
    }

    @Test("comments and string literals are not code")
    func codeStripsCommentsAndStrings() {
        let source = """
        /// NSFont.systemFont in a doc comment
        let pattern = "NSFont.systemFont(ofSize:" // and a trailing comment
        let font = NSFont.preferredFont(forTextStyle: .body)
        """
        let code = Self.code(of: source)
        #expect(!code.contains("systemFont"))
        #expect(code.contains("NSFont.preferredFont"))
    }
}
