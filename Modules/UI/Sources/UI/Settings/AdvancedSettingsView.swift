import AppKit
import SwiftUI

// MARK: - AdvancedSettingsView

public struct AdvancedSettingsView: View {
    @AppStorage("advanced.logLevel") private var logLevel = "info"
    @State private var showResetConfirm = false
    @Bindable private var backupVM: BackupSettingsViewModel

    public init(backupVM: BackupSettingsViewModel) {
        self.backupVM = backupVM
    }

    public var body: some View {
        Form {
            Section("iCloud Backup") {
                Toggle("Back up library database to iCloud Drive on launch", isOn: self.$backupVM.isEnabled)
                    .disabled(!self.backupVM.iCloudAvailable)
                    .help("Keeps up to 3 rolling backups in iCloud Drive › Documents › Bocan.")

                LabeledContent("Last backup") {
                    Text(self.backupVM.lastBackupDescription)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await self.backupVM.backupNow() }
                } label: {
                    if self.backupVM.isBackingUp {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Backing up…")
                        }
                    } else {
                        Text("Back Up Now")
                    }
                }
                .disabled(!self.backupVM.iCloudAvailable || self.backupVM.isBackingUp)
                .help("Writes a consistent snapshot using the SQLite backup API.")

                if !self.backupVM.iCloudAvailable {
                    Text("iCloud Drive is not available on this Mac. Sign in to iCloud in System Settings to enable backups.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let err = self.backupVM.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .task { await self.backupVM.load() }

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
        let dbURL = support.appendingPathComponent("Bocan/library.sqlite")
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
