import AudioEngine
import Foundation
import Observability

/// On-disk layout for transcoded sync artifacts (ADR-088): the workspace of
/// prepare-and-release.
///
/// Artifacts are derived data, but bytes inside the prepare window are
/// promised to the phone (`sha256`, `If-Match`), so they live in Application
/// Support, which macOS never purges, not Caches, which it may. The release
/// sweep in `TranscodeCoordinator` is the deliberate cleanup policy. The root
/// is excluded from Time Machine: everything here is regenerable.
///
/// Layout: `<appSupport>/io.cloudcauldron.bocan/SyncTranscodes/<preset>/<trackID>-<hash prefix>.<ext>`
public struct TranscodeStore: Sendable {
    private let root: URL
    private let log = AppLogger.make(.sync)

    /// - Parameter root: override the storage root (tests pass a temp
    ///   directory). `nil` uses the default Application Support location.
    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
    }

    private static let defaultRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("io.cloudcauldron.bocan", isDirectory: true)
            .appendingPathComponent("SyncTranscodes", isDirectory: true)
    }()

    // MARK: - Paths

    /// The deterministic artifact path for one (track, source hash, preset).
    /// The source-hash prefix in the name makes a stale artifact for a
    /// retagged file a *different* path, never a wrong serve.
    public func artifactURL(trackID: Int64, sourceContentHash: String, preset: TranscodePreset) -> URL {
        self.root
            .appendingPathComponent(preset.rawValue, isDirectory: true)
            .appendingPathComponent("\(trackID)-\(sourceContentHash.prefix(12)).\(preset.fileExtension)")
    }

    /// `true` when the artifact's bytes are on disk.
    public func exists(trackID: Int64, sourceContentHash: String, preset: TranscodePreset) -> Bool {
        FileManager.default.fileExists(
            atPath: self.artifactURL(trackID: trackID, sourceContentHash: sourceContentHash, preset: preset).path
        )
    }

    // MARK: - Mutations

    /// Creates the preset's directory (and the root, marked excluded from
    /// Time Machine). Idempotent; call before each encode.
    public func prepareDirectory(preset: TranscodePreset) throws {
        let presetDir = self.root.appendingPathComponent(preset.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)
        do {
            var rootURL = self.root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try rootURL.setResourceValues(values)
        } catch {
            // Backup inclusion is harmless; keep going.
            self.log.warning("transcode.store.backup_exclusion.failed", [
                "error": String(reflecting: error),
            ])
        }
    }

    /// Removes one artifact's bytes if present. Never throws: a release sweep
    /// must not die on one stubborn file.
    public func removeArtifact(trackID: Int64, sourceContentHash: String, preset: TranscodePreset) {
        let url = self.artifactURL(trackID: trackID, sourceContentHash: sourceContentHash, preset: preset)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            self.log.warning("transcode.store.remove.failed", [
                "path": url.lastPathComponent,
                "error": String(reflecting: error),
            ])
        }
    }

    /// Removes a whole preset rung's directory (preset switch, or Original
    /// selected). Never throws.
    public func removePreset(_ preset: TranscodePreset) {
        let dir = self.root.appendingPathComponent(preset.rawValue, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            self.log.warning("transcode.store.remove_preset.failed", [
                "preset": preset.rawValue,
                "error": String(reflecting: error),
            ])
        }
    }
}
