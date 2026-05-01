import Foundation
import Library
import Persistence
import SwiftUI

// MARK: - NewSmartPlaylistSheet

/// Simple sheet to name a new smart playlist before opening the rule builder.
struct NewSmartPlaylistSheet: View {
    let service: SmartPlaylistService
    let parentID: Int64?
    let onCreated: (SmartPlaylist) async -> Void

    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var suggestedName = ""
    @State private var selectedParentID: Int64?
    @State private var availableFolders: [PlaylistNode] = []
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var isNameFocused: Bool

    init(
        service: SmartPlaylistService,
        parentID: Int64? = nil,
        onCreated: @escaping (SmartPlaylist) async -> Void
    ) {
        self.service = service
        self.parentID = parentID
        self._selectedParentID = State(initialValue: parentID)
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("New Smart Playlist")
                .font(Typography.largeTitle)
                .foregroundStyle(Color.textPrimary)

            TextField("Name", text: self.$name)
                .textFieldStyle(.roundedBorder)
                .focused(self.$isNameFocused)
                .frame(minWidth: 280)
                .onSubmit { Task { await self.save() } }

            Picker("Folder", selection: self.$selectedParentID) {
                Text("Top Level").tag(nil as Int64?)
                ForEach(self.availableFolders, id: \.id) { folder in
                    Text(folder.name).tag(Optional(folder.id))
                }
            }

            if let error = self.error {
                Text(error)
                    .font(Typography.footnote)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") { self.dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    Task { await self.save() }
                } label: {
                    if self.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.name.trimmingCharacters(in: .whitespaces).isEmpty || self.isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 340)
        .onAppear {
            self.isNameFocused = true
            Task { @MainActor in SmartPlaylistSurfacePrewarmer.prewarmOnce() }
            self.bootstrapContext()
            Task { await self.seedDefaultNameIfNeeded() }
        }
        .onChange(of: self.selectedParentID) { _, _ in
            self.refreshSuggestedNameIfNeeded()
        }
    }

    private var trimmedName: String {
        self.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sidebarVM: PlaylistSidebarViewModel? {
        PlaylistSidebarViewModel.activeForNewPlaylistSheet
    }

    private func save() async {
        let trimmed = self.trimmedName
        guard !trimmed.isEmpty else { return }
        self.isSaving = true
        do {
            let uniqueName = self.resolveUniqueSiblingName(base: trimmed)
            // Create with a minimal default criterion: title contains ""
            let defaultCriteria = SmartCriterion.group(.and, [
                .rule(SmartCriterion.Rule(
                    field: .title,
                    comparator: .contains,
                    value: .text("")
                )),
            ])
            let defaultLimitSort = LimitSort(liveUpdate: SmartPlaylistPreferences.defaultLiveUpdate())
            let playlist = try await self.service.create(
                name: uniqueName,
                criteria: defaultCriteria,
                limitSort: defaultLimitSort,
                parentID: self.selectedParentID,
                presetKey: nil
            )
            let sp = try await self.service.resolve(id: playlist.id ?? -1)
            if let createdID = sp.playlist.id {
                self.library.requestSmartPlaylistRuleBuilder(for: createdID)
                await self.library.selectDestination(.smartPlaylist(createdID))
            }
            await self.onCreated(sp)
        } catch {
            self.error = error.localizedDescription
            self.isSaving = false
        }
    }

    private func bootstrapContext() {
        if let vm = self.sidebarVM {
            self.availableFolders = vm.foldersForParentPicker()
        }
    }

    private func seedDefaultNameIfNeeded() async {
        guard self.name.isEmpty else { return }
        let base = Self.defaultNameBase()
        let candidate = self.resolveUniqueSiblingName(base: base)
        self.suggestedName = candidate
        self.name = candidate
    }

    private func refreshSuggestedNameIfNeeded() {
        self.availableFolders = self.sidebarVM?.foldersForParentPicker() ?? []
        let candidate = self.resolveUniqueSiblingName(base: Self.defaultNameBase())
        let shouldReplace = self.trimmedName.isEmpty || self.trimmedName == self.suggestedName
        self.suggestedName = candidate
        if shouldReplace {
            self.name = candidate
        }
    }

    private func resolveUniqueSiblingName(base: String) -> String {
        if let vm = self.sidebarVM {
            return vm.uniqueSiblingName(base: base, parentID: self.selectedParentID)
        }
        return base
    }

    private static func defaultNameBase(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "New Smart Playlist \(formatter.string(from: date))"
    }
}
