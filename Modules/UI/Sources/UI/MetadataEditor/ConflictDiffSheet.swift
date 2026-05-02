import SwiftUI

// MARK: - ConflictDiffSheet

/// Side-by-side comparison of the user's stored tag values vs. what's on disk,
/// shown when the Tag Editor detects a `needs_conflict_review` conflict.
///
/// The diff is intentionally read-only — the user resolves the conflict via
/// "Keep My Edits" or "Take Disk Version" in the `TagEditorSheet` banner.
public struct ConflictDiffSheet: View {
    @ObservedObject public var vm: TagEditorViewModel
    @Binding public var isPresented: Bool

    public init(vm: TagEditorViewModel, isPresented: Binding<Bool>) {
        self.vm = vm
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text("Field-by-field Comparison")
                    .font(.headline)
                Spacer()
                Button("Done") { self.isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Close diff sheet")
            }
            .padding()

            Divider()

            if self.vm.conflictDiffRows.isEmpty {
                ContentUnavailableView(
                    "No Differences Found",
                    systemImage: "checkmark.circle",
                    description: Text(
                        "The tracked fields (title, genre, year, etc.) are identical. " +
                            "Artist / album names are not compared here."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Column headers
                HStack(spacing: 0) {
                    Text("Field")
                        .frame(width: 110, alignment: .leading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading)
                    Divider().frame(maxHeight: 20)
                    Text("Your Edits (stored)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                    Divider().frame(maxHeight: 20)
                    Text("On Disk (new)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                .padding(.vertical, 6)
                .background(.background.secondary)

                Divider()

                List(self.vm.conflictDiffRows, id: \.id) { row in
                    DiffRow(row: row)
                        .listRowSeparator(.visible)
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer with resolution actions
            HStack {
                Text("Resolve via the banner in the Tag Editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Keep My Edits") {
                    Task {
                        await self.vm.keepMyEdits()
                        self.isPresented = false
                    }
                }
                .help("Preserve your stored tag values; acknowledge the on-disk change")
                Button("Take Disk Version") {
                    Task {
                        await self.vm.takeDiskVersion()
                        self.isPresented = false
                    }
                }
                .help("Accept the on-disk tags; your edits will be discarded")
            }
            .padding()
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 320, idealHeight: 420)
    }
}

// MARK: - DiffRow

private struct DiffRow: View {
    let row: TagEditorViewModel.ConflictDiffRow

    var body: some View {
        HStack(spacing: 0) {
            Text(self.row.label)
                .frame(width: 110, alignment: .leading)
                .font(.subheadline.weight(.medium))
                .padding(.leading)
                .padding(.vertical, 4)
            Divider()
            Text(self.row.stored.isEmpty ? "—" : self.row.stored)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(self.row.stored.isEmpty ? .tertiary : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            Divider()
            Text(self.row.disk.isEmpty ? "—" : self.row.disk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(self.row.disk.isEmpty ? .tertiary : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(self.row.label): stored \(self.row.stored), on disk \(self.row.disk)"
        )
    }
}
