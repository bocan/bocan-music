import Library
import Persistence
import SwiftUI

// MARK: - NewSmartPlaylistSheet

/// Simple sheet to name a new smart playlist before opening the rule builder.
struct NewSmartPlaylistSheet: View {
    let service: SmartPlaylistService
    let onCreated: (SmartPlaylist) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = "New Smart Playlist"
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var isNameFocused: Bool

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
        .onAppear { self.isNameFocused = true }
    }

    private func save() async {
        let trimmed = self.name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        self.isSaving = true
        do {
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
                name: trimmed,
                criteria: defaultCriteria,
                limitSort: defaultLimitSort,
                parentID: nil,
                presetKey: nil
            )
            let sp = try await self.service.resolve(id: playlist.id ?? -1)
            await self.onCreated(sp)
        } catch {
            self.error = error.localizedDescription
            self.isSaving = false
        }
    }
}
