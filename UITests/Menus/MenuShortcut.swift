import Foundation

// MARK: - MenuShortcut

/// A keyboard shortcut in normalized form, comparable across its three
/// representations (phase 30 parity): the manifest declaration, the Swift
/// source (`KeyboardShortcut(...)` / `.keyboardShortcut(...)`), and the
/// help book's display strings ("⌘⇧O").
struct MenuShortcut: Hashable, CustomStringConvertible {
    enum Key: Hashable {
        case char(Character) // stored lowercased
        case space
        case returnKey
        case delete
        case upArrow, downArrow, leftArrow, rightArrow
    }

    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    let key: Key
    let modifiers: Modifiers

    init(_ key: Key, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Canonical display, macOS modifier order (⌃⌥⇧⌘).
    var description: String {
        var out = ""
        if self.modifiers.contains(.control) { out += "⌃" }
        if self.modifiers.contains(.option) { out += "⌥" }
        if self.modifiers.contains(.shift) { out += "⇧" }
        if self.modifiers.contains(.command) { out += "⌘" }
        switch self.key {
        case let .char(c): out += String(c).uppercased()
        case .space: out += "Space"
        case .returnKey: out += "↩"
        case .delete: out += "⌫"
        case .upArrow: out += "↑"
        case .downArrow: out += "↓"
        case .leftArrow: out += "←"
        case .rightArrow: out += "→"
        }
        return out
    }

    // MARK: Display-string parsing ("⌘⇧O", "⌘→", "Space")

    /// Parses a help-book display string. Modifier order is not significant.
    static func fromDisplay(_ display: String) -> MenuShortcut? {
        var modifiers: Modifiers = []
        var rest = Substring(display)
        loop: while let first = rest.first {
            switch first {
            case "⌘": modifiers.insert(.command)
            case "⇧": modifiers.insert(.shift)
            case "⌥": modifiers.insert(.option)
            case "⌃": modifiers.insert(.control)
            default: break loop
            }
            rest = rest.dropFirst()
        }
        guard let key = self.key(fromDisplayToken: String(rest)) else { return nil }
        return MenuShortcut(key, modifiers)
    }

    private static func key(fromDisplayToken token: String) -> Key? {
        switch token {
        case "Space", "␣": return .space
        case "↩", "⏎": return .returnKey
        case "⌫": return .delete
        case "↑": return .upArrow
        case "↓": return .downArrow
        case "←": return .leftArrow
        case "→": return .rightArrow
        default:
            guard token.count == 1, let c = token.first else { return nil }
            return .char(Character(String(c).lowercased()))
        }
    }

    // MARK: Swift-source parsing

    /// Parses the argument list of `KeyboardShortcut(...)` or
    /// `.keyboardShortcut(...)`: a key literal (`"o"`, `" "`, `.return`,
    /// `.rightArrow`, ...) plus an optional `modifiers:` clause. An omitted
    /// modifiers clause means `.command` (the SwiftUI default).
    static func fromSwiftArguments(_ arguments: String) -> MenuShortcut? {
        let key: Key? = if let literal = self.firstStringLiteral(in: arguments) {
            literal == " " ? .space : literal.count == 1
                ? .char(Character(literal.lowercased()))
                : nil
        } else {
            self.namedKey(in: arguments)
        }
        guard let key else { return nil }

        guard let modifiersRange = arguments.range(of: "modifiers:") else {
            return MenuShortcut(key, .command)
        }
        var modifiers: Modifiers = []
        let clause = arguments[modifiersRange.upperBound...]
        if clause.contains(".command") { modifiers.insert(.command) }
        if clause.contains(".shift") { modifiers.insert(.shift) }
        if clause.contains(".option") { modifiers.insert(.option) }
        if clause.contains(".control") { modifiers.insert(.control) }
        return MenuShortcut(key, modifiers)
    }

    private static func firstStringLiteral(in text: String) -> String? {
        guard let open = text.firstIndex(of: "\""),
              let close = text[text.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(text[text.index(after: open) ..< close])
    }

    private static func namedKey(in text: String) -> Key? {
        let names: [(String, Key)] = [
            (".return", .returnKey), (".delete", .delete), (".space", .space),
            (".upArrow", .upArrow), (".downArrow", .downArrow),
            (".leftArrow", .leftArrow), (".rightArrow", .rightArrow),
        ]
        return names.first { text.contains($0.0) }?.1
    }
}
