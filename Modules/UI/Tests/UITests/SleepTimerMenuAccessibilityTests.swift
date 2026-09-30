import AppKit
import Foundation
import Testing
@testable import UI

// MARK: - SleepTimerMenuAccessibilityTests

/// #586: a borderless `Menu` exposes its label image's own accessibility
/// description, so the sleep timer button said "do not disturb" (the moon
/// symbol's name) whatever the timer was doing. The label now draws an image
/// that carries the timer's state.
@MainActor
@Suite("Sleep timer menu accessibility")
struct SleepTimerMenuAccessibilityTests {
    @Test("The moon image carries the description it is given, not the symbol's name")
    func moonImageCarriesDescription() {
        let image = SleepTimerMenu.moonImage(description: "Sleep timer: Off", pointSize: 13)
        #expect(image.accessibilityDescription == "Sleep timer: Off")
    }

    @Test("The moon image grows with the point size it is given")
    func moonImageTakesPointSize() {
        let small = SleepTimerMenu.moonImage(description: "x", pointSize: 13)
        let large = SleepTimerMenu.moonImage(description: "x", pointSize: 26)
        #expect(large.size.height > small.size.height)
    }

    @Test("The menu label draws the described image with the state label")
    func menuLabelUsesDescribedImage() throws {
        // #filePath: .../Modules/UI/Tests/UITests/SleepTimerMenuAccessibilityTests.swift
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Transport/SleepTimerMenu.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("Image(nsImage: Self.moonImage(description: self.accessibilityLabel"))
        #expect(!code.contains("Image(systemName: \"moon.fill\")"))
    }
}
