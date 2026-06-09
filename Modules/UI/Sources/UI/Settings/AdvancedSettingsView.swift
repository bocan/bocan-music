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
            Section(L10n.string("iCloud Backup")) {
                Toggle(L10n.string("Back up library database to iCloud Drive on launch"), isOn: self.$backupVM.isEnabled)
                    .disabled(!self.backupVM.iCloudAvailable)
                    .help(L10n.string("Keeps up to 3 rolling backups in iCloud Drive › Documents › Bocan."))

                LabeledContent(L10n.string("Last backup")) {
                    Text(self.backupVM.lastBackupDescription)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await self.backupVM.backupNow() }
                } label: {
                    if self.backupVM.isBackingUp {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(localized: "Backing up…")
                        }
                    } else {
                        Text(localized: "Back Up Now")
                    }
                }
                .disabled(!self.backupVM.iCloudAvailable || self.backupVM.isBackingUp)
                .help(L10n.string("Writes a consistent snapshot using the SQLite backup API."))

                if !self.backupVM.iCloudAvailable {
                    Text(localized:
                        "iCloud Drive is not available on this Mac. Sign in to iCloud in System Settings to enable backups.")
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

            Section(L10n.string("Local Backup")) {
                Toggle(L10n.string("Back up library database to local storage on launch"), isOn: self.$backupVM.isLocalEnabled)
                    .help(L10n.string("Saves a rolling set of backups to ~/Library/Application Support/Bocan/Backups/."))

                Stepper(
                    L10n.string("Keep \(self.backupVM.localKeepCount) backups"),
                    value: self.$backupVM.localKeepCount,
                    in: 1 ... 20
                )
                .help(L10n.string("How many local backup files to retain. Older ones are deleted automatically."))

                LabeledContent(L10n.string("Last backup")) {
                    Text(self.backupVM.lastLocalBackupDescription)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        Task { await self.backupVM.backupLocalNow() }
                    } label: {
                        if self.backupVM.isLocalBackingUp {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(localized: "Backing up…")
                            }
                        } else {
                            Text(localized: "Back Up Now")
                        }
                    }
                    .disabled(self.backupVM.isLocalBackingUp)
                    .help(L10n.string("Writes a consistent snapshot to the local backup folder."))

                    Button(L10n.string("Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [self.backupVM.localBackupDirectory]
                        )
                    }
                    .help(L10n.string("Opens ~/Library/Application Support/Bocan/Backups/ in Finder."))
                }

                if let err = self.backupVM.localErrorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.string("Logging")) {
                Picker(L10n.string("Log level"), selection: self.$logLevel) {
                    Text(localized: "Debug").tag("debug")
                    Text(localized: "Info").tag("info")
                    Text(localized: "Warning").tag("warning")
                    Text(localized: "Error").tag("error")
                }
            }

            Section(L10n.string("Database")) {
                Button(L10n.string("Reveal Database in Finder")) {
                    self.revealDatabase()
                }

                Button(L10n.string("Rebuild Full-Text Search Index")) {
                    // Phase 11 will implement this
                }
                .disabled(true)
                .help(L10n.string("Not yet available"))
            }

            Section(L10n.string("Reset")) {
                Button(L10n.string("Reset All Preferences…")) {
                    self.showResetConfirm = true
                }
                .foregroundStyle(.red)
                .confirmationDialog(
                    L10n.string("Reset all preferences?"),
                    isPresented: self.$showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L10n.string("Reset"), role: .destructive) { self.resetPreferences() }
                    Button(L10n.string("Cancel"), role: .cancel) {}
                } message: {
                    Text(localized: "This cannot be undone. Bòcan will restart with default settings.")
                }

                Button(L10n.string("Export Diagnostics…")) {
                    self.exportDiagnostics()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("Advanced"))
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
