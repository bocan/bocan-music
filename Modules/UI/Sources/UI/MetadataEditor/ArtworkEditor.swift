import AppKit
import Library
import SwiftUI

// MARK: - ArtworkEditor

/// Cover-art editor pane inside the tag editor.
///
/// Supports: show current art, choose file, paste from clipboard, fetch online,
/// drag-drop onto the view, and remove.
public struct ArtworkEditor: View {
    @ObservedObject public var vm: TagEditorViewModel
    @Binding public var isPresentingFetchSheet: Bool

    public init(vm: TagEditorViewModel, isPresentingFetchSheet: Binding<Bool>) {
        self.vm = vm
        self._isPresentingFetchSheet = isPresentingFetchSheet
    }

    @State private var isTargeted = false

    public var body: some View {
        VStack(alignment: .center, spacing: 12) {
            // Art preview — pending change takes priority over the loaded art.
            Group {
                let displayData = self.vm.pendingArtData ?? self.vm.existingArtData
                if let data = displayData, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .overlay(
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(Color.textTertiary)
                        )
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(self.isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .onDrop(of: [.image, .fileURL], isTargeted: self.$isTargeted) { providers in
                self.handleDrop(providers: providers)
            }
            .accessibilityLabel("Cover art")

            // Action buttons
            HStack(spacing: 8) {
                Button("Choose File…") { self.chooseFile() }
                Button("Paste") { self.pasteFromClipboard() }
                    .disabled(!NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil))
                Button("Fetch…") { self.isPresentingFetchSheet = true }
                if self.vm.pendingArtData != nil || self.vm.existingArtData != nil {
                    Button("Remove") { self.vm.clearArtwork() }
                        .foregroundStyle(.red)
                }
            }
            .buttonStyle(.bordered)
            .font(Typography.footnote)
        }
        .padding()
    }

    // MARK: - Private actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .webP, .gif]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to use as cover art"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? Data(contentsOf: url) {
            self.vm.pendingArtData = Self.normalise(data)
        }
    }

    private func pasteFromClipboard() {
        if let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let data = img.tiffRepresentation {
            self.vm.pendingArtData = Self.normalise(data)
        }
    }

    @MainActor
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Try file URL first
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            Task { @MainActor in
                let url: URL? = await withCheckedContinuation { cont in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url as? URL) }
                }
                guard let url, let data = try? Data(contentsOf: url) else { return }
                self.vm.pendingArtData = Self.normalise(data)
            }
            return true
        }

        // Try image data (NSImage doesn't bridge via loadObject; use raw data)
        if provider.hasItemConformingToTypeIdentifier("public.image") {
            Task { @MainActor in
                let data: Data? = await withCheckedContinuation { cont in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                        cont.resume(returning: data)
                    }
                }
                guard let data else { return }
                self.vm.pendingArtData = Self.normalise(data)
            }
            return true
        }

        return false
    }

    /// Normalises image data: converts large PNG/WebP to JPEG at quality 90.
    private static func normalise(_ data: Data) -> Data {
        // Strip EXIF, convert to sRGB JPEG when > 1 MB and not already a JPEG.
        let oneMB = 1_048_576
        guard data.count > oneMB else { return data }
        guard let src = NSImage(data: data) else { return data }

        var rect = NSRect(origin: .zero, size: src.size)
        guard let cgImage = src.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return data
        }
        let bmp = NSBitmapImageRep(cgImage: cgImage)
        // swiftlint:disable:next legacy_objc_type
        let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: NSNumber(value: 0.90)]
        return bmp.representation(using: .jpeg, properties: props) ?? data
    }
}
