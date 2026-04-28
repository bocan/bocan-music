import Metadata
import SwiftUI

// MARK: - LyricsEditorSheet

/// A sheet that lets the user paste, edit, and save lyrics for the current track.
///
/// - `⌘T` inserts a LRC timestamp at the cursor from `currentPosition`.
/// - "Save" always writes to the DB; embedding into the file requires Phase 8.
public struct LyricsEditorSheet: View {
    // MARK: - Dependencies

    @ObservedObject public var vm: LyricsViewModel
    @Binding public var isPresented: Bool

    /// Current engine playback position, used by "Insert Timestamp".
    public var currentPosition: TimeInterval

    // MARK: - State

    @State private var text = ""
    @FocusState private var editorFocused: Bool
    @State private var showSaveConfirmation = false
    @AppStorage("lyrics.embedOnSave") private var embedOnSave = false

    // MARK: - Init

    public init(
        vm: LyricsViewModel,
        isPresented: Binding<Bool>,
        currentPosition: TimeInterval
    ) {
        self.vm = vm
        self._isPresented = isPresented
        self.currentPosition = currentPosition
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            self.toolbar
            Divider()
            TextEditor(text: self.$text)
                .font(.body.monospaced())
                .focused(self.$editorFocused)
                .accessibilityLabel("Lyrics editor")
                .accessibilityIdentifier(A11y.Lyrics.editor)
            Divider()
            self.footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { self.loadInitialText() }
        .onKeyPress(.init("t"), phases: .down) { event in
            guard event.modifiers == .command else { return .ignored }
            self.insertTimestamp()
            return .handled
        }
    }

    // MARK: - Sub-views

    private var toolbar: some View {
        HStack {
            Text("Edit Lyrics")
                .font(.headline)
            Spacer()
            Button("Cancel") {
                self.isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                self.saveLyrics()
                self.isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            .disabled(self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button {
                self.insertTimestamp()
            } label: {
                Label("Insert Timestamp", systemImage: "timer")
            }
            .keyboardShortcut("t", modifiers: .command)
            .help("Insert [mm:ss.xx] at cursor (⌘T)")
            .accessibilityIdentifier(A11y.Lyrics.insertTimestampButton)

            Spacer()

            Toggle("Embed in file", isOn: self.$embedOnSave)
                .toggleStyle(.checkbox)
                .help("Write lyrics back into the audio file on save (requires write permission)")

            Button("Delete") {
                self.vm.deleteLyrics()
                self.isPresented = false
            }
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func loadInitialText() {
        switch self.vm.document {
        case let .unsynced(t):
            self.text = t

        case .synced:
            self.text = self.vm.document?.toLRC() ?? ""

        case .none:
            self.text = ""
        }
        self.editorFocused = true
    }

    private func insertTimestamp() {
        let mins = Int(currentPosition) / 60
        let secs = self.currentPosition - Double(mins * 60)
        let cents = Int((secs - Double(Int(secs))) * 100)
        let stamp = String(format: "[%02d:%02d.%02d]", mins, Int(secs), cents)
        // Append at cursor; TextEditor doesn't expose cursor index on macOS,
        // so we append to the end of the current line as a pragmatic default.
        self.text += stamp
    }

    private func saveLyrics() {
        self.vm.save(text: self.text)
    }
}
