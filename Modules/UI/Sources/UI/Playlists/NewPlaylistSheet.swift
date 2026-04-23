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
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { self.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { Task { await self.commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .onAppear { self.nameFocused = true }
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

    private func commit() async {
        guard !self.isCommitting else { return }
        self.isCommitting = true
        let name = self.trimmed
        guard !name.isEmpty else {
            self.isCommitting = false
            return
        }
        _ = await self.onCreate(name)
        self.isPresented = false
    }
}
