import Library
import SwiftUI

// MARK: - LibrarySettingsView

public struct LibrarySettingsView: View {
    @EnvironmentObject private var vm: LibraryViewModel
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

            Section("Music Sources") {
                if self.vm.libraryRoots.isEmpty {
                    Text("No folders or files added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.vm.libraryRoots, id: \.id) { root in
                        let url = URL(fileURLWithPath: root.path)
                        HStack {
                            Image(systemName: url.hasDirectoryPath ? "folder" : "music.note")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                Text(root.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                if let id = root.id {
                                    Task { await self.vm.removeRoot(id: id) }
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(url.lastPathComponent) from library")
                        }
                        .help(root.path)
                    }
                }

                HStack {
                    Button("Add Folder…") {
                        Task { await self.vm.addFolderByPicker() }
                    }
                    Button("Add Files…") {
                        Task { await self.vm.addFilesByPicker() }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Library")
    }
}
