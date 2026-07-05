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
    /// The last value written into `text` programmatically, used to tell an
    /// in-progress user edit apart from a not-yet-loaded document.
    @State private var lastLoaded = ""
    @FocusState private var editorFocused: Bool
    @State private var showSaveConfirmation = false
    @State private var showDeleteConfirm = false
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
                .accessibilityLabel(L10n.string("Lyrics editor"))
                .accessibilityIdentifier(A11y.Lyrics.editor)
            Divider()
            self.footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { self.loadInitialText() }
        .onChange(of: self.vm.document) { _, _ in
            // The document can resolve after the sheet is already on screen when the
            // editor is opened for a track that was not yet being observed. Pull the
            // resolved lyrics in so the editor no longer shows stale-empty text.
            self.applyDocumentText()
        }
        .onKeyPress(.init("t"), phases: .down) { event in
            guard event.modifiers == .command else { return .ignored }
            self.insertTimestamp()
            return .handled
        }
        .confirmationDialog(
            L10n.string("Delete Lyrics?"),
            isPresented: self.$showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Delete Lyrics"), role: .destructive) {
                self.vm.deleteLyrics()
                self.isPresented = false
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(localized: "This will permanently remove all stored lyrics for the current track.")
        }
    }

    // MARK: - Sub-views

    private var toolbar: some View {
        HStack {
            Text(localized: "Edit Lyrics")
                .font(.headline)
            Spacer()
            Button(L10n.string("Cancel")) {
                self.isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Button(L10n.string("Save")) {
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
                Label(L10n.string("Insert Timestamp"), systemImage: "timer")
            }
            .keyboardShortcut("t", modifiers: .command)
            .help(L10n.string("Insert [mm:ss.xx] at cursor (⌘T)"))
            .accessibilityIdentifier(A11y.Lyrics.insertTimestampButton)

            Spacer()

            Toggle(L10n.string("Embed in file"), isOn: self.$embedOnSave)
                .toggleStyle(.checkbox)
                .help(L10n.string("Write lyrics back into the audio file on save (requires write permission)"))

            Button(L10n.string("Delete"), role: .destructive) {
                self.showDeleteConfirm = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func loadInitialText() {
        self.applyDocumentText()
        self.editorFocused = true
    }

    /// Writes the view model's resolved document into the editor text.
    ///
    /// Skips the update once the user has diverged from the last value we loaded, so
    /// a late-arriving observation can populate a freshly opened editor without
    /// clobbering edits already in progress.
    private func applyDocumentText() {
        guard self.text == self.lastLoaded else { return }
        let resolved: String = switch self.vm.document {
        case let .unsynced(t):
            t

        case .synced:
            self.vm.document?.toLRC() ?? ""

        case .none:
            ""
        }
        self.text = resolved
        self.lastLoaded = resolved
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
