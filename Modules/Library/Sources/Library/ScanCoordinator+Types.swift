import Foundation

// MARK: - Internal types

extension ScanCoordinator {
    enum ImportResult {
        case inserted(Int64), updated(Int64), skipped, conflict(Int64), error
    }

    /// One file the walker found, with the size and modification time read
    /// from its resource values.
    struct ScannedFile {
        let url: URL
        let size: Int64
        let mtime: Int64
    }

    /// The values `scan` reads once and the walk uses for every file.
    struct WalkSettings {
        let supported: Set<String>
        let concurrency: Int
        let iCloudDownload: Bool
    }

    /// The running totals of one scan pass.
    struct ScanCounts {
        var inserted = 0, updated = 0, removed = 0, errors = 0, skipped = 0

        mutating func add(_ result: ImportResult) {
            switch result {
            case .inserted:
                self.inserted += 1

            case .updated:
                self.updated += 1

            case .skipped:
                self.skipped += 1

            case .conflict:
                self.skipped += 1

            case .error:
                self.errors += 1
            }
        }
    }
}
