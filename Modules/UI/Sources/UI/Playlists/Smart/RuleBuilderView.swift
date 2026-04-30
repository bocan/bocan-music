import Library
import Persistence
import SwiftUI

// MARK: - RuleBuilderView

/// Sheet that lets the user view and edit the smart playlist rules.
/// Supports nested groups, limit/sort, and preset picker.
public struct RuleBuilderView: View {
    let smartPlaylist: SmartPlaylist
    let service: SmartPlaylistService
    let playlistService: PlaylistService?
    let onSaved: (SmartPlaylist) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var root: EditableCriterion
    @State private var limitSort: LimitSort
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showPresets = false

    public init(
        smartPlaylist: SmartPlaylist,
        service: SmartPlaylistService,
        playlistService: PlaylistService? = nil,
        onSaved: @escaping (SmartPlaylist) -> Void
    ) {
        self.smartPlaylist = smartPlaylist
        self.service = service
        self.playlistService = playlistService
        self.onSaved = onSaved
        self._root = State(wrappedValue: EditableCriterion(from: smartPlaylist.criteria))
        self._limitSort = State(wrappedValue: smartPlaylist.limitSort)
    }

    public var body: some View {
        VStack(spacing: 0) {
            self.toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CriterionEditorView(criterion: self.$root, depth: 0)
                    Divider().padding(.horizontal, 4)
                    LimitAndSortView(limitSort: self.$limitSort)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420)
        .accessibilityIdentifier(A11y.RuleBuilder.view)
        .environment(\.playlistServiceForRules, self.playlistService)
        .alert("Save Error", isPresented: Binding(
            get: { self.saveError != nil },
            set: { if !$0 { self.saveError = nil } }
        )) {
            Button("OK") { self.saveError = nil }
        } message: {
            Text(self.saveError ?? "")
        }
        .sheet(isPresented: self.$showPresets) {
            SmartPresetPickerView(service: self.service) { preset in
                self.root = EditableCriterion(from: preset.criteria)
                self.limitSort = preset.limitSort
                self.showPresets = false
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button {
                self.showPresets = true
            } label: {
                Label("Presets…", systemImage: "star")
            }
            .buttonStyle(.borderless)

            Spacer()

            Text("Edit Smart Playlist Rules")
                .font(Typography.title)
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Button("Cancel") {
                self.dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                Task { await self.save() }
            } label: {
                if self.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(self.isSaving)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(A11y.RuleBuilder.saveButton)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Save

    private func save() async {
        self.isSaving = true
        do {
            let compiled = try self.root.toSmartCriterion()
            try await self.service.update(
                id: self.smartPlaylist.id,
                name: self.smartPlaylist.name,
                criteria: compiled,
                limitSort: self.limitSort
            )
            let updated = try await self.service.resolve(id: self.smartPlaylist.id)
            self.onSaved(updated)
            self.dismiss()
        } catch {
            self.saveError = error.localizedDescription
        }
        self.isSaving = false
    }
}
