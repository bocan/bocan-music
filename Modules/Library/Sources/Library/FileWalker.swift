import Foundation

/// Walks a directory tree and emits audio file URLs.
///
/// Skips:
/// - Hidden files and directories (names starting with `.`)
/// - Package bundles (`.app`, `.bundle`, etc.)
/// - Broken symlinks
/// - iCloud placeholder files (`.icloud` suffix)
/// - Files with unsupported extensions
public enum FileWalker {
    private static let skipExtensions: Set = ["icloud"]

    /// Returns an `AsyncStream` of audio file URLs under `rootURL`.
    ///
    /// The stream completes when the directory has been fully enumerated.
    public static func walk(_ rootURL: URL, supportedExtensions: Set<String>) -> AsyncStream<URL> {
        AsyncStream { continuation in
            Task.detached(priority: .utility) {
                self.enumerate(rootURL, extensions: supportedExtensions, continuation: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Private

    private static func enumerate(
        _ url: URL,
        extensions supportedExtensions: Set<String>,
        continuation: AsyncStream<URL>.Continuation
    ) {
        let fm = FileManager.default
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
            // Skip iCloud placeholders
            if name.hasSuffix(".icloud") { continue }

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
                self.enumerate(child, extensions: supportedExtensions, continuation: continuation)
                continue
            }

            // File: check extension
            let ext = child.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            continuation.yield(child)
        }
    }
}
