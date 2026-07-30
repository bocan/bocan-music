import AppKit
import Foundation
import Testing
@testable import UI

// MARK: - TypeToSearchSeedTests

/// Unit tests for the pure eligibility table behind type-to-search (#369):
/// which keypresses seed a search and which pass through untouched.
@Suite("Type-to-search seed eligibility")
struct TypeToSearchSeedTests {
    @Test("Plain letters and digits seed the search")
    func plainCharactersSeed() {
        #expect(TypeToSearchMonitor.seedCharacter(for: "s", modifiers: []) == "s")
        #expect(TypeToSearchMonitor.seedCharacter(for: "R", modifiers: .shift) == "R")
        #expect(TypeToSearchMonitor.seedCharacter(for: "3", modifiers: []) == "3")
        #expect(TypeToSearchMonitor.seedCharacter(for: "/", modifiers: []) == "/")
    }

    @Test("Menu chords pass through")
    func menuChordsPassThrough() {
        #expect(TypeToSearchMonitor.seedCharacter(for: "f", modifiers: .command) == nil)
        #expect(TypeToSearchMonitor.seedCharacter(for: "r", modifiers: [.command, .option]) == nil)
        #expect(TypeToSearchMonitor.seedCharacter(for: "a", modifiers: .control) == nil)
        #expect(TypeToSearchMonitor.seedCharacter(for: "e", modifiers: .option) == nil)
    }

    @Test("Whitespace and control keys pass through")
    func controlKeysPassThrough() {
        #expect(TypeToSearchMonitor.seedCharacter(for: " ", modifiers: []) == nil)
        #expect(TypeToSearchMonitor.seedCharacter(for: "\t", modifiers: []) == nil)
        #expect(TypeToSearchMonitor.seedCharacter(for: "\r", modifiers: []) == nil)
        #expect(TypeToSearchMonitor.seedCharacter(for: "\u{1B}", modifiers: []) == nil) // escape
        #expect(TypeToSearchMonitor.seedCharacter(for: "\u{7F}", modifiers: []) == nil) // delete
    }

    @Test("Function and navigation keys pass through")
    func functionKeysPassThrough() {
        // Arrows and F-keys arrive as 0xF700-range private-use scalars with
        // the .function modifier; both defences must hold independently.
        #expect(TypeToSearchMonitor.seedCharacter(for: "\u{F702}", modifiers: .function) == nil)
        #expect(TypeToSearchMonitor.seedCharacter(for: "\u{F704}", modifiers: []) == nil)
    }

    @Test("Empty or multi-character input passes through")
    func degenerateInputPassesThrough() {
        #expect(TypeToSearchMonitor.seedCharacter(for: nil, modifiers: []) == nil)
        #expect(TypeToSearchMonitor.seedCharacter(for: "", modifiers: []) == nil)
        #expect(TypeToSearchMonitor.seedCharacter(for: "ab", modifiers: []) == nil)
    }
}

// MARK: - TypeToSearchConventionTests

/// Source-convention checks for the parts of type-to-search that need a live
/// window (the event monitor, focus hand-off, caret placement) and so cannot
/// run host-less.
@Suite("Type-to-search conventions")
struct TypeToSearchConventionTests {
    private func uiSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("RootView installs the monitor and seeds a fresh query")
    func rootViewInstallsMonitor() throws {
        let root = try self.uiSource("AppRoot/RootView.swift")
        #expect(
            root.contains(".background(TypeToSearchBackground(vm: self.vm))"),
            "the main window must install the type-to-search background helper"
        )
        let helper = try self.uiSource("AppRoot/TypeToSearchMonitor.swift")
        #expect(
            helper.contains("self.vm.searchQuery = String(char)"),
            "the seed character must start a fresh query"
        )
        #expect(
            helper.contains("self.vm.requestSearchFocus()"),
            "the monitor must reuse the same focus request path as \u{2318}F"
        )
    }

    @Test("The monitor swallows handled events and skips active text editing")
    func monitorGuards() throws {
        let source = try self.uiSource("AppRoot/TypeToSearchMonitor.swift")
        #expect(
            source.contains("return handled ? nil : event"),
            "handled events must be swallowed or the character would type twice"
        )
        #expect(
            source.contains("window.firstResponder is NSText"),
            "keypresses while editing text must pass through"
        )
        #expect(
            source.contains("window.attachedSheet == nil"),
            "keypresses while a sheet is up must pass through"
        )
    }

    @Test("The caret is nudged behind the seed character after focus")
    func caretMovesToEnd() throws {
        // Focus selects a text field's contents; without the nudge the second
        // keystroke would replace the seed instead of extending it.
        let source = try self.uiSource("AppRoot/TypeToSearchMonitor.swift")
        #expect(
            source.contains("editor.selectedRange = NSRange(location:"),
            "the caret must be placed after the seeded character"
        )
    }
}
