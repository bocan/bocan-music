import Library
import SwiftUI

// MARK: - LibrarySettingsView

public struct LibrarySettingsView: View {
    @EnvironmentObject private var vm: LibraryViewModel
    @AppStorage("library.watchForChanges") private var watchForChanges = true
    @AppStorage("library.quickScanByDefault") private var quickScan = false
    @AppStorage("metadata.embedCoverArt") private var embedCoverArt = false

    public init() {}

    public var body: some View {
        Form {
            Section(L10n.string("Scanning")) {
                Toggle(L10n.string("Watch folders for new files"), isOn: self.$watchForChanges)
                Toggle(L10n.string("Use quick scan by default"), isOn: self.$quickScan)
                Text(localized: "Quick scan reads only file metadata tags without computing replay gain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.string("Metadata")) {
                Toggle(L10n.string("Embed cover art directly into audio files"), isOn: self.$embedCoverArt)
                    .help(self.embedCoverArtHelp)
                if self.embedCoverArt {
                    Text(localized: "Files will be modified when you save cover art changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(localized: "Cover art is stored in Bòcan's cache only and won't be visible in other apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if self.vm.libraryRoots.isEmpty {
                    Text(localized: "No folders or files added yet.")
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
                            .help(L10n.string("Remove \(url.lastPathComponent) from library (does not delete files on disk)"))
                            .accessibilityLabel(L10n.string("Remove \(url.lastPathComponent) from library"))
                        }
                        .help(root.path)
                    }
                }

                HStack {
                    Button(L10n.string("Add Folder…")) {
                        Task { await self.vm.addFolderByPicker() }
                    }
                    .help(L10n.string("Choose a folder containing music to add to your library"))
                    .accessibilityLabel(L10n.string("Add folder to library"))
                    Button(L10n.string("Add Files…")) {
                        Task { await self.vm.addFilesByPicker() }
                    }
                    .help(L10n.string("Choose individual audio files to add to your library"))
                    .accessibilityLabel(L10n.string("Add files to library"))
                }
                .buttonStyle(.borderless)
            } header: {
                HStack(spacing: 6) {
                    Text(localized: "Music Sources")
                    if self.vm.isScanning {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.leading, 2)
                        Text(self.vm.scanCurrentPath.isEmpty ? L10n.string("Scanning…") : self.vm.scanCurrentPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .leading)
                        Spacer()
                        Button(L10n.string("Cancel")) {
                            self.vm.cancelScan()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(L10n.string("Cancel the in-progress library scan"))
                        .accessibilityLabel(L10n.string("Cancel library scan"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("Library"))
    }

    /// Help copy for the embed toggle. Two full-sentence keys joined in code;
    /// each sentence is independently translatable (#314).
    private var embedCoverArtHelp: String {
        L10n.string("When on, saving cover art rewrites the audio file to embed the image.")
            + " "
            + L10n.string("When off, art is stored only in Bòcan's cache and won't appear in other apps.")
    }
}
