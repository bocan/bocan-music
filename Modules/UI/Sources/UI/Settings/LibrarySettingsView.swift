import SwiftUI

// MARK: - LibrarySettingsView

public struct LibrarySettingsView: View {
    @AppStorage("library.watchForChanges") private var watchForChanges = true
    @AppStorage("library.quickScanByDefault") private var quickScan = false

    public init() {}

    public var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Watch folders for new files", isOn: self.$watchForChanges)
                Toggle("Use quick scan by default", isOn: self.$quickScan)
                Text("Quick scan reads only file metadata tags without computing replay gain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Root Folders") {
                Text("Manage library folders from the File menu or drag folders into the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Library")
    }
}
