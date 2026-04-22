import GRDB

/// Assembles and exposes the ordered list of database migrations.
///
/// Add new migration structs to `make()` in numeric order.
/// **Never edit a migration that has already been merged to `main`** — append a new one instead.
public struct Migrator {
    // MARK: - Properties

    /// The migrations registered with this migrator, in application order.
    public let migrations: [String]

    // MARK: - Init

    private init(inner: DatabaseMigrator) {
        self.inner = inner
        self.migrations = inner.migrations
    }

    private let inner: DatabaseMigrator

    // MARK: - Factory

    /// Returns a `Migrator` with all application migrations registered.
    public static func make() -> Self {
        var dm = DatabaseMigrator()
        #if DEBUG
            // In debug builds we want schema changes to surface immediately.
            dm.eraseDatabaseOnSchemaChange = false
        #endif
        M001InitialSchema.register(in: &dm)
        M002PhaseThree.register(in: &dm)
        M003ForceGapless.register(in: &dm)
        M004AlbumExcludedFromShuffle.register(in: &dm)
        M005TrackYearText.register(in: &dm)
        M006BackfillAlbumCoverArt.register(in: &dm)
        M007PlaylistKindAccent.register(in: &dm)
        M008SmartLimitSort.register(in: &dm)
        return Self(inner: dm)
    }

    // MARK: - Migration

    /// Applies any pending migrations to `writer`.
    public mutating func migrate(_ writer: some DatabaseWriter) throws {
        try self.inner.migrate(writer)
    }
}
