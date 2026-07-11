import Foundation
import Observability
import Persistence

/// The top-level Phone Sync server actor: owns the mutual-TLS `NWListener`, its
/// Bonjour advertisement, the pairing ceremony, and the change observer, and
/// exposes the small lifecycle + pairing surface the App and Settings drive.
///
/// It composes the module's internal collaborators (the `Router`, `FileServing`,
/// `ManifestBuilder`, the pairing and trust actors) from a `Database` and a
/// `ServerIdentity`, so callers never touch the internal HTTP types. This is a
/// separate listener/identity/port from any future Phase 18 remote-control
/// service; the two share no trust store.
public actor SyncServer {
    private let identity: ServerIdentity
    private let trusted: TrustedDevices
    private let pairing: PairingCoordinator
    private let libraryObserver: LibraryChangeObserver
    private let listener: SyncListener
    private let log = AppLogger.make(.sync)

    private var running = false
    private var boundPort: UInt16?

    /// - Parameters:
    ///   - database: the shared library database.
    ///   - identity: the server's TLS identity (injectable for tests).
    ///   - ui: the pairing UI bridge (Settings implements it in phase 22-8).
    ///   - downloadRoot: the podcast download root (nil uses the default).
    ///   - serverName: the advertised computer name, injected so the module does
    ///     not import AppKit (`Host.current().localizedName` from the App).
    ///   - config: tunables (change-debounce window).
    public init(
        database: Database,
        identity: ServerIdentity,
        ui: any PairingUIBridge,
        downloadRoot: URL? = nil,
        serverName: @escaping @Sendable () -> String,
        config: SyncServerConfig = .default
    ) {
        self.identity = identity

        let meta = SyncMetaRepository(database: database)
        let profileRepository = SyncProfileRepository(database: database)
        let trusted = TrustedDevices(repository: TrustedDeviceRepository(database: database))
        self.trusted = trusted

        let pairing = PairingCoordinator(
            identity: identity,
            trusted: trusted,
            ui: ui,
            serverName: serverName,
            serverId: { await (try? meta.serverId()) ?? "" }
        )
        self.pairing = pairing

        self.libraryObserver = LibraryChangeObserver(syncMeta: meta, debounce: config.changeDebounce)

        let builder = ManifestBuilder(database: database, downloadRoot: downloadRoot)
        let fileServing = FileServing(database: database, downloadRoot: downloadRoot)
        let routes = PairingRoutes.routes(coordinator: pairing)
            + ManifestRoutes.routes(
                builder: builder,
                profileRepository: profileRepository,
                syncMeta: meta,
                serverName: serverName
            )
            + fileServing.routes()
        let router = Router(routes: routes)

        self.listener = SyncListener(
            identity: identity,
            router: router,
            trusted: trusted.fingerprints,
            pairingMode: { pairing.pairingMode.isOn },
            serviceName: serverName
        )
    }

    /// Whether the listener is bound and advertising.
    public var isRunning: Bool {
        self.running
    }

    /// The bound ephemeral port, or nil while stopped (for tests and diagnostics).
    public var port: UInt16? {
        self.boundPort
    }

    /// Binds the listener on an ephemeral port, seeds the trusted set, starts the
    /// change observer, wires pairing-mode changes to the Bonjour TXT, and begins
    /// advertising. Idempotent.
    public func start() async throws {
        guard !self.running else { return }
        try await self.trusted.start()
        await self.libraryObserver.start()

        let port = try await self.listener.start(advertise: true)
        self.boundPort = port

        // Reflect pairing-mode changes in the advertised TXT `pm` field. Fires
        // immediately with the current state (0 at rest).
        let listener = self.listener
        await self.pairing.observePairingMode { on in
            Task { await listener.updatePairingMode(on) }
        }

        self.running = true
        self.log.debug("sync.start", ["port": String(port)])
    }

    /// Exits any pairing window (reverting `pm` to 0), withdraws the Bonjour
    /// advertisement, closes the listener, and stops the observers. Idempotent.
    public func stop() async {
        guard self.running else { return }
        await self.pairing.cancel()
        await self.listener.stop()
        await self.libraryObserver.stop()
        await self.trusted.stop()
        self.boundPort = nil
        self.running = false
        self.log.debug("sync.stop")
    }

    /// Re-registers the Bonjour service after a wake, when the listener may have
    /// dropped it.
    public func reAdvertise() async {
        guard self.running else { return }
        await self.listener.reAdvertise()
    }

    // MARK: - Pairing pass-throughs (driven by the Settings UI in phase 22-8)

    /// Enters the pairing window (`pm` -> 1) for the coordinator's timeout.
    public func armPairing() async {
        await self.pairing.arm()
    }

    /// Force-exits the pairing window (`pm` -> 0).
    public func cancelPairing() async {
        await self.pairing.cancel()
    }

    /// The paired phones, most recently paired first (for the settings list).
    public func pairedDevices() async throws -> [TrustedDevice] {
        try await self.trusted.list()
    }

    /// Revokes a paired phone; the change takes effect on the next handshake.
    public func revoke(fingerprint: String) async throws {
        try await self.trusted.revoke(fingerprint: fingerprint)
    }
}
