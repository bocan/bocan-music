import Foundation

// MARK: - MenuSourceParsing

/// Source-level extraction for the phase 30 shortcut parity test: reads
/// `KeyBindings.swift`, the `BocanCommands*.swift` menu definitions, and
/// the help book HTML, all relative to the repo root (`#filePath`), so the
/// manifest, the bindings, the menus, and the shipped shortcut table can
/// be compared without launching the app.
enum MenuSourceParsing {
    static var repoRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // Menus/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // repo root
    }

    // MARK: KeyBindings.swift

    /// `KeyBindings` constant name to its parsed shortcut.
    static func keyBindings() throws -> [String: MenuShortcut] {
        let url = self.repoRoot.appendingPathComponent(
            "Modules/UI/Sources/UI/Common/KeyBindings.swift"
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        var bindings: [String: MenuShortcut] = [:]
        let pattern = /static let (\w+) = KeyboardShortcut\((.+)\)/
        for line in source.split(separator: "\n") {
            guard let match = line.firstMatch(of: pattern) else { continue }
            bindings[String(match.1)] = MenuShortcut.fromSwiftArguments(String(match.2))
        }
        return bindings
    }

    // MARK: BocanCommands*.swift

    /// How a menu item's shortcut is declared in source.
    enum SourceShortcut: Equatable {
        case binding(String) // .keyboardShortcut(KeyBindings.<name>)
        case inline(MenuShortcut) // .keyboardShortcut("r", modifiers: ...)
    }

    /// One `Button` call site that carries a `.keyboardShortcut`. Dynamic
    /// labels (ternaries) contribute every literal on the `Button` line.
    struct ShortcutSite: Equatable {
        let titles: [String]
        let shortcut: SourceShortcut
    }

    /// Every shortcut-carrying menu item across the `BocanCommands` files.
    static func commandShortcutSites() throws -> [ShortcutSite] {
        let files = [
            "App/BocanCommands.swift",
            "App/BocanCommands+Track.swift",
            "App/BocanCommands+Tools.swift",
            "App/BocanCommands+CollectionViewMenu.swift",
        ]
        var sites: [ShortcutSite] = []
        for file in files {
            let url = self.repoRoot.appendingPathComponent(file)
            let source = try String(contentsOf: url, encoding: .utf8)
            sites += self.shortcutSites(in: source)
        }
        return sites
    }

    private static func shortcutSites(in source: String) -> [ShortcutSite] {
        var sites: [ShortcutSite] = []
        var currentTitles: [String] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            if line.contains("Button(") {
                currentTitles = self.stringLiterals(in: line).map(self.unescaped)
            }
            guard let range = line.range(of: ".keyboardShortcut(") else { continue }
            let arguments = self.balancedParenContents(
                of: String(line[range.upperBound...])
            )
            let shortcut: SourceShortcut? = if let bindingMatch = arguments.firstMatch(of: /KeyBindings\.(\w+)/) {
                .binding(String(bindingMatch.1))
            } else if let inline = MenuShortcut.fromSwiftArguments(arguments) {
                .inline(inline)
            } else {
                nil
            }
            if let shortcut, !currentTitles.isEmpty {
                sites.append(ShortcutSite(titles: currentTitles, shortcut: shortcut))
            }
        }
        return sites
    }

    /// Text up to the parenthesis matching an already-consumed `(`.
    private static func balancedParenContents(of text: String) -> String {
        var depth = 1
        var out = ""
        for char in text {
            if char == "(" { depth += 1 }
            if char == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            out.append(char)
        }
        return out
    }

    private static func stringLiterals(in line: String) -> [String] {
        line.matches(of: /"([^"]*)"/).map { String($0.1) }
    }

    /// Resolves `\u{2026}`-style escapes the way the compiler would.
    private static func unescaped(_ literal: String) -> String {
        var out = literal
        while let match = out.firstMatch(of: /\\u\{([0-9A-Fa-f]+)\}/) {
            guard let value = UInt32(match.1, radix: 16),
                  let scalar = Unicode.Scalar(value) else { break }
            out.replaceSubrange(match.range, with: String(Character(scalar)))
        }
        return out
    }

    // MARK: Help book

    static var helpBookURL: URL {
        self.repoRoot.appendingPathComponent(
            "HelpBook/Bocan.help/Contents/Resources/en.lproj/index.html"
        )
    }

    /// The Keyboard Shortcuts table: action name to display string.
    static func helpBookTableRows() throws -> [(action: String, display: String)] {
        let html = try String(contentsOf: self.helpBookURL, encoding: .utf8)
        return html.matches(of: /<tr><td>([^<]+)<\/td><td>([^<]+)<\/td><\/tr>/)
            .map { (action: String($0.1), display: String($0.2)) }
    }

    /// Every shortcut-looking token anywhere in the help book, prose
    /// included, so a wrong shortcut in running text is caught too (the
    /// phase 27 bug class).
    static func helpBookShortcutTokens() throws -> [String] {
        let html = try String(contentsOf: self.helpBookURL, encoding: .utf8)
        return html.matches(of: /[⌘⇧⌥⌃]+(?:→|←|↑|↓|↩|⌫|[A-Z0-9?.,])/)
            .map { String($0.output) }
    }
}
