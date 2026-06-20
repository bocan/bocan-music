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
        M009AcoustID.register(in: &dm)
        M010DSPAssignments.register(in: &dm)
        M011LyricsOffset.register(in: &dm)
        M012Scrobbling.register(in: &dm)
        M013CueVirtualTracks.register(in: &dm)
        M014ForeignKeyActions.register(in: &dm)
        M015TrackExtendedTags.register(in: &dm)
        M016SmartLastSnapshotAt.register(in: &dm)
        M017SmartRandomSeed.register(in: &dm)
        M018ConflictReviewFlag.register(in: &dm)
        M019PlaylistTrackUnique.register(in: &dm)
        M020SubsonicServers.register(in: &dm)
        M021SubsonicScrobble.register(in: &dm)
        M022ScrobbleIgnoredRollup.register(in: &dm)
        M023Podcasts.register(in: &dm)
        M024PodcastGUID.register(in: &dm)
        M025PodcastFundingText.register(in: &dm)
        M026PodcastTranscript.register(in: &dm)
        M027PodcastPerShowSettings.register(in: &dm)
        return Self(inner: dm)
    }

    // MARK: - Migration

    /// Applies any pending migrations to `writer`.
    public mutating func migrate(_ writer: some DatabaseWriter) throws {
        try self.inner.migrate(writer)
    }

    /// Applies migrations up to and including `target`. Exists so tests of
    /// data-repair migrations can seed pre-migration fixtures, then finish
    /// migrating; production code always uses `migrate(_:)`.
    public mutating func migrate(_ writer: some DatabaseWriter, upTo target: String) throws {
        try self.inner.migrate(writer, upTo: target)
    }
}
