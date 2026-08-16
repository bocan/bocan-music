import AppKit
import Foundation
import Library
import Observability
import Persistence
import UniformTypeIdentifiers

// MARK: - Listening-history import (ADR-076 slice 1)

/// The Last.fm export import: file picker, one-shot run with a summary
/// toast, the re-match pass, and the one-statement undo. Imported plays
/// never touch local counters; see `ListenImportRepository`.
public extension LibraryViewModel {
    /// Opens a file panel for a Last.fm export CSV and imports it.
    func importListeningHistoryByPicker() async {
        guard !self.isImportingListens else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = L10n.string("Choose a Last.fm listening-history export (a CSV with uts, artist, and track columns).")
        panel.prompt = L10n.string("Import")
        let response = await Self.runOpenPanelAsync(panel)
        guard response == .OK, let url = panel.urls.first else { return }
        await self.importListeningHistory(from: url)
    }

    /// Imports the export at `url`. Exposed separately so tests can skip the
    /// panel; the summary (or a readable failure) lands as a toast.
    func importListeningHistory(from url: URL) async {
        guard !self.isImportingListens else { return }
        self.isImportingListens = true
        defer { self.isImportingListens = false }
        do {
            let summary = try await ListeningHistoryImporter(database: self.database).importExport(at: url)
            self.showToast(ToastMessage(text: Self.importToast(summary), kind: .success))
        } catch {
            AppLogger.make(.library).error("listens.import.failed", ["error": String(reflecting: error)])
            self.showToast(ToastMessage(
                text: L10n.string("That file could not be read as a Last.fm export"),
                kind: .info
            ))
        }
    }

    /// Re-runs the match pass, for after the library has grown.
    func rematchImportedListens() async {
        do {
            let summary = try await ListenImportRepository(database: self.database).rematch()
            self.showToast(ToastMessage(
                text: L10n.string("\(summary.newlyMatched) more listens matched to your library"),
                kind: .success
            ))
        } catch {
            AppLogger.make(.library).error("listens.rematch.failed", ["error": String(reflecting: error)])
        }
    }

    /// Deletes all imported history. The Listening Behaviour pane confirms
    /// before calling this; local plays are untouched.
    func removeImportedListens() async {
        do {
            let removed = try await ListenImportRepository(database: self.database).removeAll()
            self.showToast(ToastMessage(
                text: L10n.string("Removed \(removed) imported listens"),
                kind: .info
            ))
        } catch {
            AppLogger.make(.library).error("listens.remove.failed", ["error": String(reflecting: error)])
        }
    }
}

private extension LibraryViewModel {
    static func importToast(_ summary: ListeningHistoryImporter.Summary) -> String {
        guard summary.inserted > 0 else {
            return L10n.string("Nothing new to import: that export is already in")
        }
        let awaiting = summary.totalStored - summary.totalMatched
        return L10n.string("Imported \(summary.inserted) listens: \(summary.totalMatched) matched, \(awaiting) awaiting a match")
    }
}
