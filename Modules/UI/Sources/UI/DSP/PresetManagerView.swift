import AudioEngine
import SwiftUI

// MARK: - PresetManagerView

/// Manages user-created EQ presets: rename, duplicate, delete.
/// Built-in presets are shown as read-only references.
public struct PresetManagerView: View {
    @Bindable var vm: DSPViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var renameID: EQPreset.ID?
    @State private var renameDraft = ""

    public init(vm: DSPViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text("Manage EQ Presets")
                .font(.headline)
                .padding()

            Divider()

            List {
                if !BuiltInPresets.all.isEmpty {
                    Section("Built-in") {
                        ForEach(BuiltInPresets.all) { preset in
                            self.presetRow(preset, isBuiltIn: true)
                        }
                    }
                }

                let userPresets = self.vm.presets.filter { !$0.isBuiltIn }
                if !userPresets.isEmpty {
                    Section("Your Presets") {
                        ForEach(userPresets) { preset in
                            self.presetRow(preset, isBuiltIn: false)
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                self.vm.deleteUserPreset(id: userPresets[i].id)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { self.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 360, height: 480)
    }

    // MARK: - Row

    private func presetRow(_ preset: EQPreset, isBuiltIn: Bool) -> some View {
        HStack {
            if self.renameID == preset.id {
                TextField("Name", text: self.$renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.commitRename(preset: preset) }
                    .accessibilityLabel("Rename preset")
                Button("OK") { self.commitRename(preset: preset) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Text(preset.name)
                Spacer()
                if !isBuiltIn {
                    Button {
                        self.renameDraft = preset.name
                        self.renameID = preset.id
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename \(preset.name)")

                    Button { self.duplicate(preset: preset) } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Duplicate \(preset.name)")

                    Button(role: .destructive) {
                        self.vm.deleteUserPreset(id: preset.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(preset.name)")
                } else {
                    Label("Built-in", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.iconOnly)
                }
            }
        }
    }

    // MARK: - Actions

    private func commitRename(preset: EQPreset) {
        let name = self.renameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { self.renameID = nil
            return
        }
        let updated = EQPreset(
            id: preset.id,
            name: name,
            bandGainsDB: preset.bandGainsDB,
            isBuiltIn: false,
            outputGainDB: preset.outputGainDB
        )
        self.vm.presetStore.save(updated)
        self.vm.presets = self.vm.presetStore.allPresets
        self.renameID = nil
    }

    private func duplicate(preset: EQPreset) {
        let copy = EQPreset(
            id: UUID().uuidString,
            name: "\(preset.name) Copy",
            bandGainsDB: preset.bandGainsDB,
            isBuiltIn: false,
            outputGainDB: preset.outputGainDB
        )
        self.vm.presetStore.save(copy)
        self.vm.presets = self.vm.presetStore.allPresets
    }
}
