import Library
import SwiftUI
import UniformTypeIdentifiers

/// Sheet for exporting a single playlist to disk.
public struct PlaylistExportSheet: View {
    @Binding public var isPresented: Bool
    public let exporter: PlaylistExportService
    public let playlistID: Int64
    public let playlistName: String

    @State private var format: PlaylistFormat = .m3u8
    @State private var pathStyle: PathStyle = .absolute
    @State private var relativeRoot: URL?
    @State private var errorMessage: String?
    @State private var isExporting = false

    public init(
        isPresented: Binding<Bool>,
        exporter: PlaylistExportService,
        playlistID: Int64,
        playlistName: String
    ) {
        self._isPresented = isPresented
        self.exporter = exporter
        self.playlistID = playlistID
        self.playlistName = playlistName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export “\(self.playlistName)”")
                .font(.title2.weight(.semibold))

            Form {
                Picker("Format", selection: self.$format) {
                    Text("M3U8").tag(PlaylistFormat.m3u8)
                    Text("M3U").tag(PlaylistFormat.m3u)
                    Text("PLS").tag(PlaylistFormat.pls)
                    Text("XSPF").tag(PlaylistFormat.xspf)
                }

                Picker("Paths", selection: self.$pathStyle) {
                    Text("Absolute").tag(PathStyle.absolute)
                    Text("Relative").tag(PathStyle.relative)
                }

                if self.pathStyle == .relative {
                    HStack {
                        Text(self.relativeRoot?.path ?? "Choose root…")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Choose…") { self.pickRoot() }
                    }
                }
            }
            .formStyle(.grouped)

            if let error = self.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { self.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { Task { await self.runExport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.isExporting || (self.pathStyle == .relative && self.relativeRoot == nil))
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }

    enum PathStyle: Hashable { case absolute, relative }

    private func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { self.relativeRoot = panel.url }
    }

    private func runExport() async {
        let save = NSSavePanel()
        save.nameFieldStringValue = "\(self.playlistName).\(self.format.preferredExtension)"
        if let type = UTType(filenameExtension: self.format.preferredExtension) {
            save.allowedContentTypes = [type]
        }
        guard save.runModal() == .OK, let dest = save.url else { return }
        self.isExporting = true
        defer { self.isExporting = false }

        let pathMode: PathMode = switch self.pathStyle {
        case .absolute:
            .absolute

        case .relative:
            self.relativeRoot.map(PathMode.relative(to:)) ?? .absolute
        }

        do {
            try await self.exporter.export(.init(
                playlistID: self.playlistID,
                destination: dest,
                format: self.format,
                pathMode: pathMode
            ))
            self.isPresented = false
        } catch {
            self.errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
