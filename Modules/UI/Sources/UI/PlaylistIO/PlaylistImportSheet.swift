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
            Text("Import Playlist")
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
                Button("Choose Files…") { self.pickFiles() }
                Spacer()
                Button("Cancel", role: .cancel) { self.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { Task { await self.runImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.pickedURLs.isEmpty || self.isImporting)
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
            Text("Pick one or more playlist files (.m3u, .m3u8, .pls, .xspf).")
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
                    Text("\(row.matched) matched")
                        .font(.caption2).foregroundStyle(.green)
                }
                if row.missed > 0 {
                    Text("\(row.missed) missing")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .frame(minHeight: 200)
    }

    // MARK: - Actions

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let exts = ["m3u", "m3u8", "pls", "xspf"]
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        self.pickedURLs = panel.urls
        Task { await self.refreshPreview() }
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
                    "M3U playlist"

                case .m3u8:
                    "M3U8 playlist"

                case .pls:
                    "PLS playlist"

                case .xspf:
                    "XSPF playlist"

                case .cue:
                    "CUE sheet"

                case .itunesXML:
                    "iTunes Library.xml"

                case nil:
                    "Unknown format"
                }
                rows.append(PreviewRow(id: url, url: url, summary: summary, matched: 0, missed: 0))
            } catch {
                rows.append(PreviewRow(id: url, url: url, summary: "Could not read", matched: 0, missed: 0))
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
                self.errorMessage = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
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
