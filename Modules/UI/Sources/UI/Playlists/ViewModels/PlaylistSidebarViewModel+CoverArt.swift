import AppKit
import Foundation

// MARK: - PlaylistSidebarViewModel cover-art file helpers

extension PlaylistSidebarViewModel {
    /// Copies the image at `url` into the per-playlist-covers directory and
    /// returns its new absolute path. Converts non-JPEG formats to JPEG @90%.
    nonisolated static func saveImageFile(url: URL, playlistID: Int64) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let raw = try Data(contentsOf: url)
                    let dir = Self.playlistCoversDirectory()
                    try FileManager.default.createDirectory(
                        at: dir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    let stamp = Int64(Date().timeIntervalSince1970)
                    let filename = "playlist_\(playlistID)_\(stamp).jpg"
                    let dest = dir.appendingPathComponent(filename)
                    let jpeg = Self.normaliseToJPEG(raw) ?? raw
                    try jpeg.write(to: dest, options: .atomic)
                    continuation.resume(returning: dest.path)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// `~/Library/Application Support/Bocan/playlist_covers/`
    nonisolated static func playlistCoversDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Bocan/playlist_covers", isDirectory: true)
    }

    /// Converts arbitrary image data to JPEG @90% quality. Returns `nil` if the
    /// input is already a JPEG or the conversion fails.
    nonisolated static func normaliseToJPEG(_ data: Data) -> Data? {
        // JPEG magic bytes: FF D8 FF
        if data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF]) { return nil }
        guard let img = NSImage(data: data) else { return nil }
        var rect = NSRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let bmp = NSBitmapImageRep(cgImage: cg)
        // swiftlint:disable:next legacy_objc_type
        let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: NSNumber(value: 0.90)]
        return bmp.representation(using: .jpeg, properties: props)
    }

    /// Async wrapper around `NSOpenPanel.begin(completionHandler:)`.
    /// Does NOT spin a modal run loop; safe to call during active playback.
    static func openPanelAsync(
        _ panel: NSOpenPanel
    ) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { (c: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { response in c.resume(returning: response) }
        }
    }
}
