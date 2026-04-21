import Library
import SwiftUI

// MARK: - RenamePlaylistSheet

/// Sheet for renaming a playlist or folder.
public struct RenamePlaylistSheet: View {
    @Binding public var target: PlaylistNode?
    public let onRename: (PlaylistNode, String) async -> Void

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    public init(target: Binding<PlaylistNode?>, onRename: @escaping (PlaylistNode, String) async -> Void) {
        self._target = target
        self.onRename = onRename
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename")
                .font(Typography.title)

            Form {
                TextField("Name", text: self.$name)
                    .focused(self.$nameFocused)
                    .onSubmit { Task { await self.commit() } }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { self.target = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { Task { await self.commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .onAppear {
            self.name = self.target?.name ?? ""
            self.nameFocused = true
        }
    }

    private func commit() async {
        guard let t = target else { return }
        let trimmed = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await self.onRename(t, trimmed)
        self.target = nil
    }
}
