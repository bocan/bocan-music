import Library
import SwiftUI
import UniformTypeIdentifiers

/// Sheet presenting a file picker, format-aware preview, and a confirmation
/// step for importing a playlist into the user's library.
public struct PlaylistImportSheet: View {
    @Binding public var isPresented: Bool
    public let importer: PlaylistImportService
    public let onImported: (Int64) -> Void

    @State private var pickedURLs: [URL] = []
    @State private var preview: [PreviewRow] = []
    @State private var isImporting = false
    @State private var errorMessage: String?

    public init(
        isPresented: Binding<Bool>,
        importer: PlaylistImportService,
        onImported: @escaping (Int64) -> Void
    ) {
        self._isPresented = isPresented
        self.importer = importer
        self.onImported = onImported
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized: "Import Playlist")
                .font(.title2.weight(.semibold))

            if self.pickedURLs.isEmpty {
                self.empty
            } else {
                self.previewList
            }

            if let error = self.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button(L10n.string("Choose Files…")) { self.pickFiles() }
                    .help(L10n.string("Open a file picker to select one or more playlist files to import"))
                    .accessibilityLabel(L10n.string("Choose playlist files"))
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) { self.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .help(L10n.string("Dismiss this sheet without importing"))
                Button(L10n.string("Import")) { Task { await self.runImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.pickedURLs.isEmpty || self.isImporting)
                    .help(
                        self.pickedURLs.isEmpty
                            ? L10n.string("Select at least one playlist file before importing")
                            : L10n.string("Import the selected playlist files into your library")
                    )
                    .accessibilityLabel(
                        self.isImporting ? L10n.string("Importing, please wait") : L10n.string("Import selected playlists")
                    )
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 320)
    }

    // MARK: - Subviews

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(localized: "Pick one or more playlist files (.m3u, .m3u8, .pls, .xspf).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private var previewList: some View {
        List(self.preview) { row in
            HStack {
                VStack(alignment: .leading) {
                    Text(row.url.lastPathComponent).font(.body.weight(.medium))
                    Text(row.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if row.matched > 0 {
                    Text(localized: "\(row.matched) matched")
                        .font(.caption2).foregroundStyle(.green)
                }
                if row.missed > 0 {
                    Text(localized: "\(row.missed) missing")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .accessibilityLabel(Self.rowAccessibilityLabel(for: row))
        }
        .frame(minHeight: 200)
    }

    private static func rowAccessibilityLabel(for row: PreviewRow) -> String {
        var parts = [row.url.lastPathComponent, row.summary]
        if row.matched > 0 { parts.append(L10n.string("\(row.matched) matched")) }
        if row.missed > 0 { parts.append(L10n.string("\(row.missed) missing")) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Actions

    private func pickFiles() {
        // Use begin(completionHandler:) — non-blocking, never stalls the main run loop
        // or the audio render thread. Matches the async-panel pattern from Phase 5.5.
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            let exts = ["m3u", "m3u8", "pls", "xspf", "cue"]
            panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
            let result = await withCheckedContinuation { cont in
                panel.begin { cont.resume(returning: $0) }
            }
            guard result == .OK else { return }
            self.pickedURLs = panel.urls
            await self.refreshPreview()
        }
    }

    private func refreshPreview() async {
        var rows: [PreviewRow] = []
        for url in self.pickedURLs {
            // Light-weight pre-resolution: just count entries.
            do {
                let data = try Data(contentsOf: url)
                let format = PlaylistFormat.sniff(data: data, fallback: url.pathExtension)
                let summary = switch format {
                case .m3u:
                    L10n.string("M3U playlist")

                case .m3u8:
                    L10n.string("M3U8 playlist")

                case .pls:
                    L10n.string("PLS playlist")

                case .xspf:
                    L10n.string("XSPF playlist")

                case .cue:
                    L10n.string("CUE sheet")

                case .itunesXML:
                    L10n.string("iTunes Library.xml")

                case nil:
                    L10n.string("Unknown format")
                }
                let counts = await self.importer.previewFile(at: url)
                rows.append(PreviewRow(id: url, url: url, summary: summary, matched: counts.matched, missed: counts.missed))
            } catch {
                rows.append(PreviewRow(id: url, url: url, summary: L10n.string("Could not read"), matched: 0, missed: 0))
            }
        }
        await MainActor.run { self.preview = rows }
    }

    private func runImport() async {
        self.isImporting = true
        defer { self.isImporting = false }
        var lastID: Int64?
        for url in self.pickedURLs {
            do {
                let report = try await self.importer.importFile(at: url, parentID: nil)
                lastID = report.playlistID
            } catch {
                self.errorMessage = L10n.string("Failed to import \(url.lastPathComponent): \(error.localizedDescription)")
                return
            }
        }
        if let id = lastID {
            self.onImported(id)
        }
        self.isPresented = false
    }
}

private struct PreviewRow: Identifiable {
    let id: URL
    let url: URL
    let summary: String
    let matched: Int
    let missed: Int
}
