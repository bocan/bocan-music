import AppKit
import SwiftUI

// MARK: - AdvancedSettingsView

public struct AdvancedSettingsView: View {
    @AppStorage("advanced.logLevel") private var logLevel = "info"
    @State private var showResetConfirm = false

    public init() {}

    public var body: some View {
        Form {
            Section("Logging") {
                Picker("Log level", selection: self.$logLevel) {
                    Text("Debug").tag("debug")
                    Text("Info").tag("info")
                    Text("Warning").tag("warning")
                    Text("Error").tag("error")
                }
            }

            Section("Database") {
                Button("Reveal Database in Finder") {
                    self.revealDatabase()
                }

                Button("Rebuild Full-Text Search Index") {
                    // Phase 11 will implement this
                }
                .disabled(true)
                .help("Not yet available")
            }

            Section("Reset") {
                Button("Reset All Preferences…") {
                    self.showResetConfirm = true
                }
                .foregroundStyle(.red)
                .confirmationDialog(
                    "Reset all preferences?",
                    isPresented: self.$showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) { self.resetPreferences() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone. Bòcan will restart with default settings.")
                }

                Button("Export Diagnostics…") {
                    self.exportDiagnostics()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
    }

    // MARK: - Actions

    private func revealDatabase() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dbURL = support.appendingPathComponent("Bocan/bocan.sqlite")
        NSWorkspace.shared.activateFileViewerSelecting([dbURL])
    }

    private func resetPreferences() {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BocanDiagnostics.zip"
        panel.begin { response in
            guard response == .OK else { return }
            // Stub: Phase 12 will implement full bundle export
        }
    }
}
