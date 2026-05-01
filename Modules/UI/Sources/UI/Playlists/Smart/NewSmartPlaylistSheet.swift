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

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
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
            Task { await self.seedDefaultNameIfNeeded() }
        }
    }

    private func save() async {
        let trimmed = self.name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        self.isSaving = true
        do {
            let uniqueName = try await self.resolveUniqueSiblingName(base: trimmed)
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
                parentID: self.parentID,
                presetKey: nil
            )
            let sp = try await self.service.resolve(id: playlist.id ?? -1)
            await self.onCreated(sp)
        } catch {
            self.error = error.localizedDescription
            self.isSaving = false
        }
    }

    private func seedDefaultNameIfNeeded() async {
        guard self.name.isEmpty else { return }
        do {
            let base = Self.defaultNameBase()
            self.name = try await self.resolveUniqueSiblingName(base: base)
        } catch {
            // If sibling lookup fails, still provide a deterministic default.
            self.name = Self.defaultNameBase()
        }
    }

    private func resolveUniqueSiblingName(base: String) async throws -> String {
        let siblings = try await self.service
            .listAll()
            .filter { $0.parentID == self.parentID }
        return Self.uniqueName(base: base, siblings: siblings)
    }

    private static func uniqueName(base: String, siblings: [Playlist]) -> String {
        let existing = Set(siblings.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) {
            return base
        }
        var suffix = 2
        while true {
            let candidate = "\(base) (\(suffix))"
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func defaultNameBase(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "New Smart Playlist \(formatter.string(from: date))"
    }
}
