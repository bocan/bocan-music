import Foundation

/// Marks a folder that holds only rebuildable data so backup tools skip it
/// (#569).
///
/// Two marks, because backup tools disagree on what they honour:
/// - A `CACHEDIR.TAG` file (https://bford.info/cachedir/), which GNU `tar
///   --exclude-caches`, Borg and restic honour. Time Machine does not.
/// - `URLResourceValues.isExcludedFromBackup`, which Time Machine honours.
///   Only for folders under Application Support: Time Machine already skips
///   `~/Library/Caches`.
///
/// Safe to call on every launch and before every write. The tag is written
/// once; the exclusion flag is set every time, because it lives on the
/// folder itself and is lost when the folder is deleted and made again.
/// Nothing here is fatal: a failure is logged and the cache keeps working.
///
/// Never mark a folder Bòcan cannot rebuild (the library database, `CoverArt`,
/// `EditBackups`, `Backups`, podcast downloads, playlist covers); see #569.
public enum CacheDirectoryMarker {
    public static let tagFileName = "CACHEDIR.TAG"

    /// The line a tag must begin with, byte for byte.
    public static let signatureLine = "Signature: 8a477f597d28d172789f06886806bc55"

    static let tagContents = Self.signatureLine + "\n"
        + "# This file is a cache directory tag created by Bòcan.\n"
        + "# For information about cache directory tags see https://bford.info/cachedir/\n"

    /// Mark `directory` as a cache. Does nothing when it does not exist, so an
    /// owner can call this at launch to mark a folder left by an older
    /// version, and again right after it creates the folder.
    ///
    /// - Parameters:
    ///   - excludeFromBackup: also set `isExcludedFromBackup` (for folders
    ///     under Application Support).
    ///   - log: the owner's logger, so a failure shows under its category.
    public static func mark(_ directory: URL, excludeFromBackup: Bool, log: AppLogger = .make(.app)) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let tag = directory.appendingPathComponent(Self.tagFileName, isDirectory: false)
        if !FileManager.default.fileExists(atPath: tag.path) {
            do {
                try Data(Self.tagContents.utf8).write(to: tag, options: .atomic)
                log.debug("cache.mark.tagged", ["path": directory.path])
            } catch {
                log.warning("cache.mark.failed", [
                    "path": directory.path, "step": "tag", "error": String(reflecting: error),
                ])
            }
        }

        guard excludeFromBackup else { return }
        do {
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            log.warning("cache.mark.failed", [
                "path": directory.path, "step": "excludeFromBackup", "error": String(reflecting: error),
            ])
        }
    }
}
