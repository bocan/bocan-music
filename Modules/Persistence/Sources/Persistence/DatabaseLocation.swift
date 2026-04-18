import Foundation

/// Resolves the filesystem path for the SQLite database file.
///
/// The canonical location is `~/Library/Application Support/Bocan/library.sqlite`.
/// Pass `.inMemory` when running tests to avoid touching the filesystem.
public enum DatabaseLocation: Sendable {
    /// The canonical on-disk path inside `Application Support/Bocan/`.
    case application

    /// An ephemeral, per-connection in-memory database (for tests).
    case inMemory

    /// A caller-supplied URL, for migration helpers and CI fixtures.
    case custom(URL)

    // MARK: - Internal

    /// The resolved URL, or `nil` for in-memory databases.
    var url: URL? {
        switch self {
        case .application:
            Self.applicationSupportURL

        case .inMemory:
            nil

        case let .custom(url):
            url
        }
    }

    /// The `Application Support/Bocan` directory, created if it does not exist.
    private static var applicationSupportURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        let dir = base.appendingPathComponent("Bocan", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return dir.appendingPathComponent("library.sqlite")
    }
}
