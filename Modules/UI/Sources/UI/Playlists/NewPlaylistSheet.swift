import Library
import SwiftUI

// MARK: - NewPlaylistSheet

/// Sheet used to create a new playlist or folder.
public struct NewPlaylistSheet: View {
    public enum Kind { case playlist, folder }

    public let kind: Kind
    @Binding public var isPresented: Bool
    public let parentID: Int64?
    public let onCreate: (String) async -> Int64?

    @State private var name = ""
    @State private var suggestedName = ""
    @State private var selectedParentID: Int64?
    @State private var availableFolders: [PlaylistNode] = []
    @State private var includeSelection = false
    @State private var pendingSelectionCount = 0
    @State private var isCommitting = false
    @FocusState private var nameFocused: Bool

    public init(
        kind: Kind,
        isPresented: Binding<Bool>,
        parentID: Int64?,
        onCreate: @escaping (String) async -> Int64?
    ) {
        self.kind = kind
        self._isPresented = isPresented
        self.parentID = parentID
        self._selectedParentID = State(initialValue: parentID)
        self.onCreate = onCreate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(self.title)
                .font(Typography.title)
                .foregroundStyle(Color.textPrimary)

            Form {
                TextField("Name", text: self.$name)
                    .focused(self.$nameFocused)
                    .accessibilityIdentifier(A11y.PlaylistSidebar.newNameField)
                    .onSubmit { Task { await self.commit() } }

                if self.kind == .playlist {
                    Picker("Folder", selection: self.$selectedParentID) {
                        Text("Top Level").tag(nil as Int64?)
                        ForEach(self.availableFolders, id: \.id) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }

                    if self.pendingSelectionCount > 0 {
                        Toggle(
                            "From selection (\(self.pendingSelectionCount) track\(self.pendingSelectionCount == 1 ? "" : "s"))",
                            isOn: self.$includeSelection
                        )
                        .help("Preload this playlist with the current track selection")
                        .accessibilityLabel("Create from current selection")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { self.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { Task { await self.commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.trimmed.isEmpty || self.isCommitting)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .onAppear {
            self.nameFocused = true
            self.bootstrapContext()
        }
        .onChange(of: self.selectedParentID) { _, _ in
            self.refreshSuggestedNameIfNeeded()
        }
    }

    private var title: String {
        switch self.kind {
        case .playlist:
            "New Playlist"

        case .folder:
            "New Folder"
        }
    }

    private var trimmed: String {
        self.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sidebarVM: PlaylistSidebarViewModel? {
        PlaylistSidebarViewModel.activeForNewPlaylistSheet
    }

    private func bootstrapContext() {
        guard self.kind == .playlist else { return }

        if let vm = self.sidebarVM {
            self.availableFolders = vm.foldersForParentPicker()
            self.pendingSelectionCount = vm.pendingSelectionForNewPlaylist().count
            self.includeSelection = self.pendingSelectionCount > 0
            let candidate = vm.defaultPlaylistName(parentID: self.selectedParentID)
            self.suggestedName = candidate
            if self.trimmed.isEmpty {
                self.name = candidate
            }
        } else {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let fallback = "New Playlist \(formatter.string(from: Date()))"
            self.suggestedName = fallback
            if self.trimmed.isEmpty {
                self.name = fallback
            }
        }
    }

    private func refreshSuggestedNameIfNeeded() {
        guard self.kind == .playlist else { return }
        guard let vm = self.sidebarVM else { return }
        self.availableFolders = vm.foldersForParentPicker()
        let candidate = vm.defaultPlaylistName(parentID: self.selectedParentID)
        let shouldReplace = self.trimmed.isEmpty || self.trimmed == self.suggestedName
        self.suggestedName = candidate
        if shouldReplace {
            self.name = candidate
        }
    }

    private func commit() async {
        guard !self.isCommitting else { return }
        self.isCommitting = true
        let name = self.trimmed
        guard !name.isEmpty else {
            self.isCommitting = false
            return
        }
        let createdID: Int64? = if self.kind == .playlist, let vm = self.sidebarVM {
            await vm.createPlaylist(
                name: name,
                parentID: self.selectedParentID,
                includePendingSelection: self.includeSelection
            )
        } else {
            await self.onCreate(name)
        }
        if createdID == nil {
            self.isCommitting = false
            return
        }
        self.isPresented = false
    }
}
