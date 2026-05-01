import AppKit
import Library
import Persistence
import SwiftUI

// MARK: - PlaylistSidebarSection

/// Renders the "Playlists" section in the sidebar.
///
/// Hierarchy is flattened manually (rather than using `OutlineGroup`) so the
/// enclosing `List` can still drive a `selection` on `SidebarDestination`.
public struct PlaylistSidebarSection: View {
    @ObservedObject public var vm: PlaylistSidebarViewModel
    public let smartPlaylistService: SmartPlaylistService

    public init(vm: PlaylistSidebarViewModel, smartPlaylistService: SmartPlaylistService) {
        self.vm = vm
        self.smartPlaylistService = smartPlaylistService
    }

    public var body: some View {
        Section {
            if self.vm.nodes.isEmpty {
                Text("No playlists yet")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.vertical, 2)
            } else {
                ForEach(self.vm.flattened(), id: \.node.id) { entry in
                    self.row(for: entry.node, depth: entry.depth)
                }
            }
        } header: {
            HStack {
                Text("Playlists")
                Spacer()
                Menu {
                    Button("New Playlist") { self.vm.beginNewPlaylist() }
                    Button("New Smart Playlist") { self.vm.beginNewSmartPlaylist() }
                    Button("New Folder") { self.vm.beginNewFolder() }
                } label: {
                    Image(systemName: "plus")
                        .font(Typography.footnote)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Create a new playlist, smart playlist, or folder")
                .accessibilityLabel("New Playlist or Folder")
                .accessibilityIdentifier(A11y.PlaylistSidebar.addButton)
            }
        }
        .task { await self.vm.reload() }
        // NOTE: Sheet / confirmationDialog presentation modifiers MUST be
        // attached to the enclosing `List` (not this `Section`) — see
        // `View.playlistSidebarPresentations` below. SwiftUI replicates
        // modifiers attached to a `Section` once per row, which caused the
        // name-entry sheet to flicker N times where N == row count.
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for node: PlaylistNode, depth: Int) -> some View {
        if node.kind == .folder {
            PlaylistFolderRow(node: node, depth: depth, vm: self.vm)
                .tag(SidebarDestination.folder(node.id))
        } else if node.kind == .smart {
            PlaylistRow(node: node, depth: depth, vm: self.vm)
                .tag(SidebarDestination.smartPlaylist(node.id))
        } else {
            PlaylistRow(node: node, depth: depth, vm: self.vm)
                .tag(SidebarDestination.playlist(node.id))
        }
    }
}

// MARK: - Presentation modifiers

/// Public extension that exposes the `playlistSidebarPresentations` modifier.
public extension View {
    /// Attaches the playlist-sidebar's sheets and confirmation dialogs to a
    /// non-collection ancestor view (typically the enclosing `List`).
    ///
    /// These modifiers must NOT be attached to `PlaylistSidebarSection`
    /// directly: SwiftUI replicates modifiers placed on a `Section` once per
    /// row in the section's content, causing presentation animations to
    /// fire N times where N is the row count.
    func playlistSidebarPresentations(
        vm: PlaylistSidebarViewModel,
        smartPlaylistService: SmartPlaylistService
    ) -> some View {
        modifier(PlaylistSidebarPresentationsModifier(
            vm: vm,
            smartPlaylistService: smartPlaylistService
        ))
    }
}

private struct PlaylistSidebarPresentationsModifier: ViewModifier {
    @ObservedObject var vm: PlaylistSidebarViewModel
    let smartPlaylistService: SmartPlaylistService

    func body(content: Content) -> some View {
        content
            .modifier(PlaylistSidebarSurfacePrewarmModifier())
            .modifier(NewPlaylistSheetModifier(vm: self.vm))
            .modifier(NewFolderSheetModifier(vm: self.vm))
            .modifier(NewSmartPlaylistSheetModifier(vm: self.vm, smartPlaylistService: self.smartPlaylistService))
            .modifier(RenameSheetModifier(vm: self.vm))
            .modifier(AccentColorSheetModifier(vm: self.vm))
            .modifier(DeleteDialogsModifier(vm: self.vm))
            .modifier(SidebarErrorAlertModifier(vm: self.vm))
    }
}

private struct PlaylistSidebarSurfacePrewarmModifier: ViewModifier {
    @State private var didSchedule = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !self.didSchedule else { return }
            self.didSchedule = true
            Task { @MainActor in
                PlaylistSidebarSurfacePrewarmer.prewarmOnce()
            }
        }
    }
}

@MainActor
private enum PlaylistSidebarSurfacePrewarmer {
    private static var didPrewarm = false

    static func prewarmOnce() {
        guard !self.didPrewarm else { return }
        self.didPrewarm = true

        // Warm commonly-lazy AppKit work (font + first NSWindow-backed surface)
        // off-screen so first visible sheet/dialog presentation is less likely to
        // stall audio render callbacks during active playback.
        _ = NSFont.systemFont(ofSize: 13)
        let host = NSHostingView(rootView: Color.clear.frame(width: 1, height: 1))
        let panel = NSPanel(
            contentRect: NSRect(x: -20000, y: -20000, width: 16, height: 16),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.contentView = host
        panel.orderFront(nil)
        panel.orderOut(nil)
        panel.close()
    }
}

private struct NewPlaylistSheetModifier: ViewModifier {
    @ObservedObject var vm: PlaylistSidebarViewModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { self.vm.isPresentingNewPlaylist },
            set: { self.vm.isPresentingNewPlaylist = $0 }
        )) {
            NewPlaylistSheet(
                kind: .playlist,
                isPresented: Binding(
                    get: { self.vm.isPresentingNewPlaylist },
                    set: { self.vm.isPresentingNewPlaylist = $0 }
                ),
                parentID: self.vm.newPlaylistParent
            ) { name in
                await self.vm.createPlaylist(name: name)
            }
        }
    }
}

private struct NewFolderSheetModifier: ViewModifier {
    @ObservedObject var vm: PlaylistSidebarViewModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { self.vm.isPresentingNewFolder },
            set: { self.vm.isPresentingNewFolder = $0 }
        )) {
            NewPlaylistSheet(
                kind: .folder,
                isPresented: Binding(
                    get: { self.vm.isPresentingNewFolder },
                    set: { self.vm.isPresentingNewFolder = $0 }
                ),
                parentID: self.vm.newPlaylistParent
            ) { name in
                await self.vm.createFolder(name: name)
            }
        }
    }
}

private struct NewSmartPlaylistSheetModifier: ViewModifier {
    @ObservedObject var vm: PlaylistSidebarViewModel
    let smartPlaylistService: SmartPlaylistService

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { self.vm.isPresentingNewSmartPlaylist },
            set: { self.vm.isPresentingNewSmartPlaylist = $0 }
        )) {
            NewSmartPlaylistSheet(
                service: self.smartPlaylistService
            ) { _ in
                await self.vm.reload()
                self.vm.isPresentingNewSmartPlaylist = false
            }
        }
    }
}

private struct RenameSheetModifier: ViewModifier {
    @ObservedObject var vm: PlaylistSidebarViewModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { self.vm.renameTarget },
            set: { self.vm.renameTarget = $0 }
        )) { _ in
            RenamePlaylistSheet(target: Binding(
                get: { self.vm.renameTarget },
                set: { self.vm.renameTarget = $0 }
            )) { node, newName in
                await self.vm.rename(node, to: newName)
            }
        }
    }
}

private struct DeleteDialogsModifier: ViewModifier {
    @ObservedObject var vm: PlaylistSidebarViewModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete Playlist",
                isPresented: Binding(
                    get: { self.vm.deleteTarget != nil },
                    set: { newValue in if !newValue { self.vm.deleteTarget = nil } }
                ),
                presenting: self.vm.deleteTarget
            ) { target in
                Button("Delete", role: .destructive) {
                    Task { await self.vm.delete(target) }
                }
                Button("Cancel", role: .cancel) {
                    self.vm.deleteTarget = nil
                }
            } message: { target in
                Text("Delete \"\(target.name)\"? Tracks remain in your library.")
            }
            .confirmationDialog(
                "Delete Folder and Contents",
                isPresented: Binding(
                    get: { self.vm.deleteRecursiveTarget != nil },
                    set: { newValue in if !newValue { self.vm.deleteRecursiveTarget = nil } }
                ),
                presenting: self.vm.deleteRecursiveTarget
            ) { target in
                Button("Delete Folder and Contents", role: .destructive) {
                    Task { await self.vm.delete(target, recursive: true) }
                }
                Button("Cancel", role: .cancel) {
                    self.vm.deleteRecursiveTarget = nil
                }
            } message: { target in
                Text("Delete \"\(target.name)\" and all playlists inside it? This cannot be undone. Tracks remain in your library.")
            }
    }
}

private struct AccentColorSheetModifier: ViewModifier {
    @ObservedObject var vm: PlaylistSidebarViewModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { self.vm.accentColorTarget },
            set: { self.vm.accentColorTarget = $0 }
        )) { node in
            AccentColorSheet(node: node) { hex in
                await self.vm.setAccentColor(hex, for: node.id)
            }
        }
    }
}

private struct SidebarErrorAlertModifier: ViewModifier {
    @ObservedObject var vm: PlaylistSidebarViewModel

    func body(content: Content) -> some View {
        content.alert(
            "Playlist Error",
            isPresented: Binding(
                get: { self.vm.lastError != nil },
                set: { if !$0 { self.vm.lastError = nil } }
            )
        ) {
            Button("OK") { self.vm.lastError = nil }
        } message: {
            Text(self.vm.lastError ?? "")
        }
    }
}
