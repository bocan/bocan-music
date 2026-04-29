import Foundation
import Observability

/// Walks a directory tree and emits audio file URLs.
///
/// Skips:
/// - Hidden files and directories (names starting with `.`)
/// - Package bundles (`.app`, `.bundle`, etc.)
/// - Broken symlinks
/// - iCloud placeholder files (`.icloud` suffix), unless `iCloudDownload`
///   is `true` in which case a download is requested before the file is
///   skipped (it will be picked up on the next scan when materialised).
/// - Files with unsupported extensions
public enum FileWalker {
    /// Returns an `AsyncStream` of audio file URLs under `rootURL`.
    ///
    /// The stream completes when the directory has been fully enumerated.
    ///
    /// - Parameters:
    ///   - rootURL: Directory or single file to walk.
    ///   - supportedExtensions: Lower-case file extensions to emit.
    ///   - iCloudDownload: When `true`, request download of any iCloud
    ///     placeholders encountered. Phase 3 audit H7.
    public static func walk(
        _ rootURL: URL,
        supportedExtensions: Set<String>,
        iCloudDownload: Bool = false
    ) -> AsyncStream<URL> {
        AsyncStream { continuation in
            Task.detached(priority: .utility) {
                self.enumerate(
                    rootURL,
                    extensions: supportedExtensions,
                    iCloudDownload: iCloudDownload,
                    continuation: continuation
                )
                continuation.finish()
            }
        }
    }

    // MARK: - Private

    private static let log = AppLogger.make(.library)

    private static func enumerate(
        _ url: URL,
        extensions supportedExtensions: Set<String>,
        iCloudDownload: Bool,
        continuation: AsyncStream<URL>.Continuation
    ) {
        let fm = FileManager.default

        // If the root itself is a supported audio file, yield it directly.
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else { return }

        if !isDir.boolValue {
            let ext = url.pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                continuation.yield(url)
            }
            return
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isHiddenKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .fileSizeKey,
            ],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }

        for case let child as URL in enumerator {
            let name = child.lastPathComponent
            // Skip hidden
            if name.hasPrefix(".") { continue }
            // iCloud placeholder: optionally request download, then skip.
            if name.hasSuffix(".icloud") {
                if iCloudDownload {
                    // The placeholder name is `.<original>.icloud`; the real
                    // URL is the same parent + the original name.
                    let realName = String(name.dropFirst().dropLast(".icloud".count))
                    let realURL = child.deletingLastPathComponent().appendingPathComponent(realName)
                    do {
                        try fm.startDownloadingUbiquitousItem(at: realURL)
                        self.log.debug("walker.icloud.download_requested", ["path": realURL.path])
                    } catch {
                        self.log.warning("walker.icloud.download_failed", [
                            "path": realURL.path,
                            "error": String(reflecting: error),
                        ])
                    }
                }
                continue
            }

            let resourceValues = try? child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
            )
            let isDirectory = resourceValues?.isDirectory ?? false
            let isPackage = resourceValues?.isPackage ?? false
            let isSymlink = resourceValues?.isSymbolicLink ?? false
            let isHidden = resourceValues?.isHidden ?? false

            if isHidden { continue }

            // Skip broken symlinks (resolve to target; skip if target doesn't exist)
            if isSymlink {
                let target = child.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: target.path) else { continue }
            }

            if isDirectory {
                if isPackage { continue } // skip .app etc.
                // Recurse
                self.enumerate(
                    child,
                    extensions: supportedExtensions,
                    iCloudDownload: iCloudDownload,
                    continuation: continuation
                )
                continue
            }

            // File: check extension
            let ext = child.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            continuation.yield(child)
        }
    }
}
