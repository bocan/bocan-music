import Foundation
import Testing

// MARK: - DiagnosticsSettingsConventionTests

/// Source-convention checks for `DiagnosticsSettingsView` Log Console hooks (#phase-20, step 8).
///
/// These tests read the Swift source file directly and assert that the structural
/// invariants introduced in step 8 are present: the Open Log Console button, the
/// capture toggle backed by `@AppStorage`, and the `LogStore` wiring.
/// They run in both the SPM (`make test-ui`) and the Xcode bundle test targets.
@Suite("DiagnosticsSettingsView Log Console conventions")
struct DiagnosticsSettingsConventionTests {
    // MARK: - Helpers

    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func diagnosticsSource() throws -> String {
        let url = self.uiSourcesURL.appendingPathComponent("Settings/DiagnosticsSettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Tests

    @Test("Open Log Console button is present")
    func openLogConsoleButtonPresent() throws {
        let source = try self.diagnosticsSource()
        #expect(
            source.contains("Open Log Console"),
            "DiagnosticsSettingsView must have an 'Open Log Console' button"
        )
    }

    @Test("Button opens window with id 'log-console'")
    func buttonOpensLogConsoleWindowID() throws {
        let source = try self.diagnosticsSource()
        #expect(
            source.contains("\"log-console\""),
            "The Open Log Console button must call openWindow(id: \"log-console\")"
        )
    }

    @Test("Capture in-app logs toggle is present")
    func captureTogglePresent() throws {
        let source = try self.diagnosticsSource()
        #expect(
            source.contains("Capture in-app logs"),
            "DiagnosticsSettingsView must have a 'Capture in-app logs' toggle"
        )
    }

    @Test("Capture toggle persists via AppStorage key 'console.captureEnabled'")
    func captureTogglePersistsByAppStorage() throws {
        let source = try self.diagnosticsSource()
        #expect(
            source.contains("console.captureEnabled"),
            "The capture toggle must be backed by @AppStorage with key 'console.captureEnabled'"
        )
    }

    @Test("Toggle onChange wires to LogStore.shared.isCaptureEnabled")
    func toggleWiredToLogStore() throws {
        let source = try self.diagnosticsSource()
        #expect(
            source.contains("LogStore.shared.isCaptureEnabled"),
            "The toggle's onChange must apply the preference to LogStore.shared.isCaptureEnabled"
        )
    }
}
