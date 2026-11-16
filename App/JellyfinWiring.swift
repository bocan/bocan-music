import AppKit
import AudioEngine
import Foundation
import Jellyfin
import Observability
import Persistence
import UI

// MARK: - JellyfinWiring

/// Builds the whole Jellyfin object graph in one place (ADR-097).
///
/// `BocanApp` hooks it in three places: it builds the wiring, it runs
/// `hydrate()` off the launch path, and it keeps the wake observer. The window
/// gets `sourceModel`, and Settings gets `settingsViewModel`.
///
/// There is no logic here. The rules live in the `Jellyfin` module and the view
/// models in `UI`; this type only connects them.
struct JellyfinWiring {
    let repository: JellyfinServerRepository
    let store: JellyfinServerStore
    let service: JellyfinService
    let monitor: JellyfinConnectionMonitor
    /// The favourites queue behind the star in every Jellyfin song table.
    let annotations: JellyfinAnnotations
    let sourceModel: JellyfinSourceModel
    let settingsViewModel: JellyfinSettingsViewModel

    @MainActor
    static func make(database: Database) -> Self {
        let repository = JellyfinServerRepository(database: database)
        let store = JellyfinServerStore(repository: repository)
        let service = JellyfinService(store: store)
        let monitor = JellyfinConnectionMonitor(service: service)
        let listing = JellyfinStoreSidebarListing(store: store, service: service, monitor: monitor)
        let annotations = JellyfinAnnotations(service: service)
        let sourceModel = JellyfinSourceModel(
            listing: listing,
            connectionObserver: JellyfinMonitorConnectionObserver(monitor: monitor),
            dataSource: service,
            coverArtProvider: JellyfinCoverArtProvider(service: service),
            metadataCache: JellyfinRepositoryMetadataCache(repository: repository),
            annotationDelivery: annotations
        )
        // A persisted Jellyfin destination must find its client before the window
        // restores it, so RootView runs this ahead of `restoreUIState`.
        sourceModel.bootstrap = { [service, weak sourceModel] in
            do {
                try await service.reloadClients()
            } catch {
                AppLogger.make(.app).warning("jellyfin.bootstrap.reloadClientsFailed", [
                    "error": String(reflecting: error),
                ])
            }
            await sourceModel?.reloadServers()
        }
        let settingsViewModel = JellyfinSettingsViewModel(
            store: store,
            service: service,
            monitor: monitor
        ) { [weak sourceModel] in await sourceModel?.reloadServers() }
        return Self(
            repository: repository,
            store: store,
            service: service,
            monitor: monitor,
            annotations: annotations,
            sourceModel: sourceModel,
            settingsViewModel: settingsViewModel
        )
    }

    /// Finishes Jellyfin start-up off the launch path. Each step recovers on its
    /// own, so one failure cannot stop the rest.
    func hydrate() async {
        let log = AppLogger.make(.app)
        do {
            try await self.store.migrateOrphans()
        } catch {
            log.warning("jellyfin.launch.migrateOrphansFailed", ["error": String(reflecting: error)])
        }
        do {
            try await self.service.reloadClients()
        } catch {
            log.warning("jellyfin.launch.reloadClientsFailed", ["error": String(reflecting: error)])
        }
        await self.sourceModel.reloadServers()
        do {
            for server in try await self.store.fetchAll() {
                await self.monitor.startMonitoring(serverID: server.id)
            }
        } catch {
            // No server is monitored, so every status dot stays dark.
            log.warning("jellyfin.launch.serversReadFailed", ["error": String(reflecting: error)])
        }
        do {
            try await self.repository.pruneStaleCache()
        } catch {
            log.warning("jellyfin.launch.pruneStaleCacheFailed", ["error": String(reflecting: error)])
        }
    }

    /// The play-report bridge for the scrobble service (ADR-097 slice 6).
    var scrobbleDelivery: JellyfinScrobbleDelivery {
        JellyfinScrobbleDelivery(service: self.service, store: self.store, monitor: self.monitor)
    }

    /// Builds the Jellyfin stream cache and its resolver for `QueuePlayer`
    /// (ADR-097 slice 5), and makes removing a server clear that server's
    /// cache folder. The cache is a second `SubsonicStreamCache` in its own
    /// folder, `JellyfinStreams`, beside `SubsonicStreams` in `cachesFolder`,
    /// with the same budget rules. Without it no Jellyfin song can play this
    /// session; the reason is logged and `nil` keeps the rest of the app working.
    func makeStreamResolver(cachesFolder: URL) -> JellyfinStreamResolver? {
        let log = AppLogger.make(.app)
        let folder = cachesFolder.appendingPathComponent("JellyfinStreams", isDirectory: true)
        let cache: SubsonicStreamCache
        do {
            cache = try SubsonicStreamCache(
                configuration: SubsonicStreamCache.Configuration(rootDirectory: folder),
                loader: RemoteTrackLoader(transport: URLSessionHTTPTransport())
            )
        } catch {
            log.error("jellyfin.streamCache.initFailed", [
                "dir": folder.path,
                "error": String(reflecting: error),
            ])
            return nil
        }
        let service = self.service
        // The graph is built synchronously, so the handler is set a moment
        // later. No removal can come from the UI before the window exists.
        Task {
            await service.setServerRemovedHandler { serverID in
                do {
                    try await cache.purge(serverID: serverID)
                } catch {
                    // The files stay on disk until the cache evicts them by size.
                    log.warning("jellyfin.streamCache.purgeFailed", [
                        "serverID": serverID,
                        "error": String(reflecting: error),
                    ])
                }
            }
        }
        return JellyfinStreamResolver(cache: cache, service: service, store: self.store)
    }

    /// Re-pings every monitored server as soon as the Mac wakes, so the status dot
    /// does not wait out a back-off sleep. The `Jellyfin` module does not import
    /// AppKit, so the subscription lives here, as the Subsonic one does (#274).
    func installWakeObserver() {
        let monitor = self.monitor
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await monitor.wakeAll() }
        }
    }
}
