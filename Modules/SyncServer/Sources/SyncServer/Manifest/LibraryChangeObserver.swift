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
    private let log = AppLogger.make(.sync)
    private var observationTask: Task<Void, Never>?
    private var pendingBump: Task<Void, Never>?

    public init(syncMeta: SyncMetaRepository, debounce: Duration = .seconds(5)) {
        self.syncMeta = syncMeta
        self.debounce = debounce
    }

    /// Begins observing. The observation's initial emission is ignored so the
    /// counter only bumps on an actual change.
    public func start() {
        self.observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.syncMeta.observeLibraryChanges()
            do {
                var isInitial = true
                for try await _ in stream {
                    if isInitial {
                        isInitial = false
                        continue
                    }
                    await self.scheduleBump()
                }
            } catch {
                await self.observationFailed(error)
            }
        }
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
