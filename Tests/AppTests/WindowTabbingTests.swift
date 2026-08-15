import Foundation
import Testing

// MARK: - WindowTabbingTests

/// Guards the app-wide window tabbing opt-out.
///
/// Every main window renders the same shared `LibraryViewModel`, so native
/// macOS window tabs are mirrors, not browse contexts: navigating in one
/// "tab" changes all of them. Until tabs hold per-window navigation state,
/// the app disables tabbing outright. The delegate callback cannot run
/// host-less, so this pins the source contract instead.
@Suite("Window tabbing")
struct WindowTabbingTests {
    private func appSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanApp.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Automatic window tabbing is disabled before any window exists")
    func tabbingDisabledAtLaunch() throws {
        let source = try self.appSource()
        #expect(source.contains("NSWindow.allowsAutomaticWindowTabbing = false"))
        // willFinishLaunching, not didFinish: state restoration can recreate
        // windows before didFinishLaunching, and those must not tab either.
        let willFinish = source.range(of: "func applicationWillFinishLaunching")
        let tabbing = source.range(of: "NSWindow.allowsAutomaticWindowTabbing = false")
        let didFinish = source.range(of: "func applicationDidFinishLaunching")
        let willFinishIndex = try #require(willFinish?.lowerBound)
        let tabbingIndex = try #require(tabbing?.lowerBound)
        let didFinishIndex = try #require(didFinish?.lowerBound)
        #expect(willFinishIndex < tabbingIndex && tabbingIndex < didFinishIndex)
    }
}
