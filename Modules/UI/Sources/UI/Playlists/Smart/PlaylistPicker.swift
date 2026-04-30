import Library
import Persistence
import SwiftUI

extension EnvironmentValues {
    /// `PlaylistService` instance available to nested smart-playlist rule
    /// editors. Set on the rule-builder sheet root.
    @Entry var playlistServiceForRules: PlaylistService?
}

// MARK: - PlaylistPicker

/// Hierarchical menu of *manual* playlists used as the value control for
/// `memberOf` / `notMemberOf` rules. Smart playlists are excluded — letting
/// a smart playlist reference another smart playlist is forbidden by
/// `SmartPlaylistService.rejectSmartPlaylistReferences` and would cause
/// save to fail.
struct PlaylistPicker: View {
    @Binding var selectedID: Int64

    @Environment(\.playlistServiceForRules) private var service
    @State private var nodes: [PlaylistNode] = []
    @State private var loaded = false

    var body: some View {
        Menu {
            if self.manualEntries.isEmpty {
                Text("No manual playlists yet")
                    .foregroundStyle(Color.textSecondary)
            } else {
                self.menuContent(for: self.nodes)
            }
        } label: {
            HStack {
                Text(self.labelText)
                    .font(Typography.body)
                    .foregroundStyle(self.hasSelection ? Color.textPrimary : Color.textSecondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .disabled(self.loaded && self.manualEntries.isEmpty)
        .help(self.helpText)
        .accessibilityLabel("Playlist")
        .accessibilityValue(self.labelText)
        .task(id: self.taskKey) {
            guard let service else { return }
            do {
                let fetched = try await service.list()
                self.nodes = fetched
                self.loaded = true
                // If the rule still has the sentinel default (0) or refers to
                // a playlist that no longer exists, snap to the first manual
                // playlist so the user sees a real selection.
                let manualIDs = Set(self.manualEntries.map(\.id))
                if !manualIDs.contains(self.selectedID),
                   let first = self.manualEntries.first {
                    self.selectedID = first.id
                }
            } catch {
                self.loaded = true
            }
        }
    }

    // MARK: - Menu content

    @ViewBuilder
    private func menuContent(for nodes: [PlaylistNode]) -> some View {
        // Top-level manual playlists first (no folder header).
        ForEach(nodes.filter { $0.kind == .manual }, id: \.id) { node in
            self.playlistButton(node)
        }
        // Then each folder as a Section, recursively.
        ForEach(nodes.filter { $0.kind == .folder }, id: \.id) { folder in
            let manuals = self.flattenManuals(in: folder.children)
            if !manuals.isEmpty {
                Section(folder.name) {
                    ForEach(manuals, id: \.id) { node in
                        self.playlistButton(node)
                    }
                }
            }
        }
    }

    private func playlistButton(_ node: PlaylistNode) -> some View {
        Button {
            self.selectedID = node.id
        } label: {
            if node.id == self.selectedID {
                Label(node.name, systemImage: "checkmark")
            } else {
                Text(node.name)
            }
        }
    }

    // MARK: - Derived state

    private var manualEntries: [PlaylistNode] {
        self.flattenManuals(in: self.nodes)
    }

    private func flattenManuals(in nodes: [PlaylistNode]) -> [PlaylistNode] {
        nodes.flatMap { node -> [PlaylistNode] in
            switch node.kind {
            case .manual:
                [node]

            case .folder:
                self.flattenManuals(in: node.children)

            case .smart:
                []
            }
        }
    }

    private var hasSelection: Bool {
        self.manualEntries.contains { $0.id == self.selectedID }
    }

    private var labelText: String {
        if let match = self.manualEntries.first(where: { $0.id == self.selectedID }) {
            return match.name
        }
        if self.loaded, self.manualEntries.isEmpty {
            return "No manual playlists"
        }
        return "Choose a playlist…"
    }

    private var helpText: String {
        if self.loaded, self.manualEntries.isEmpty {
            return "Create a manual playlist first to use this rule"
        }
        return "Pick a manual playlist"
    }

    /// `task(id:)` only re-runs when the identifier changes. We want one
    /// load per service instance.
    private var taskKey: ObjectIdentifier? {
        self.service.map(ObjectIdentifier.init)
    }
}
