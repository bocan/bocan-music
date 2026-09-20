import Foundation
import Observability
import Persistence

/// Bumps the `sync_meta` generation counter when the library changes, debounced
/// so a burst of edits bumps the counter once. The phone polls the counter via
/// `/v1/ping` to decide whether to re-sync. Profile edits count as changes (the
/// `sync_profile` table is in the observed set), so a profile change with an
/// unchanged library still triggers a re-sync.
public actor LibraryChangeObserver {
    private let syncMeta: SyncMetaRepository
    private let debounce: Duration
    private let profile: (@Sendable () async -> SyncProfile)?
    private let log = AppLogger.make(.sync)
    private var observationTask: Task<Void, Never>?
    private var pendingBump: Task<Void, Never>?

    /// - Parameter profile: reads the current sync profile, so the observed
    ///   `tracks` region can be narrowed to the manifest's own columns when
    ///   membership cannot depend on anything else (#550). Omit it to observe
    ///   the whole table, which is always correct and never narrower.
    public init(
        syncMeta: SyncMetaRepository,
        debounce: Duration = .seconds(5),
        profile: (@Sendable () async -> SyncProfile)? = nil
    ) {
        self.syncMeta = syncMeta
        self.debounce = debounce
        self.profile = profile
    }

    /// Begins observing. The observation's initial emission is ignored so the
    /// counter only bumps on an actual change.
    public func start() {
        self.observationTask = Task { [weak self] in
            guard let self else { return }
            // Re-subscribes when a profile change flips which `tracks` region
            // is correct, and only then.
            while !Task.isCancelled {
                guard await self.observeUntilRegionChanges() else { return }
            }
        }
    }

    /// Runs one subscription. Returns `true` when it ended because the region
    /// needs recomputing, `false` when the caller should stop.
    private func observeUntilRegionChanges() async -> Bool {
        let narrow = await self.canNarrowTracksRegion()
        let stream = await self.syncMeta.observeLibraryChanges(narrowTracksToManifestColumns: narrow)
        var regionIsStale = false
        do {
            var isInitial = true
            for try await _ in stream {
                if isInitial {
                    isInitial = false
                    continue
                }
                self.scheduleBump()
                // The profile is in the observed set, so this is where a
                // change to it lands; the bump above still happens for it.
                if await self.canNarrowTracksRegion() != narrow {
                    regionIsStale = true
                    break
                }
            }
        } catch {
            self.observationFailed(error)
            return false
        }
        return regionIsStale && !Task.isCancelled
    }

    /// `true` only when library membership cannot depend on a `tracks` column
    /// outside the manifest's own set. A profile that selects playlists can
    /// include a smart playlist whose criteria key on `play_count`, so only
    /// "everything" qualifies.
    private func canNarrowTracksRegion() async -> Bool {
        guard let profile = self.profile else { return false }
        if case .everything = await profile() {
            return true
        }
        return false
    }

    public func stop() {
        self.observationTask?.cancel()
        self.observationTask = nil
        self.pendingBump?.cancel()
        self.pendingBump = nil
    }

    private func scheduleBump() {
        self.pendingBump?.cancel()
        let syncMeta = self.syncMeta
        let debounce = self.debounce
        let log = self.log
        self.pendingBump = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            do {
                _ = try await syncMeta.bumpGeneration()
            } catch {
                log.warning("generation.bump.failed", ["error": String(reflecting: error)])
            }
        }
    }

    private func observationFailed(_ error: any Error) {
        self.log.warning("generation.observe.failed", ["error": String(reflecting: error)])
    }
}
