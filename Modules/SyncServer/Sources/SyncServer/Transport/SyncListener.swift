import Foundation
import Network
import Observability
import os

/// Owns the `NWListener` for the Phone Sync server: builds the mutual-TLS
/// parameters from the `ServerIdentity`, accepts connections, and hands each to
/// an `HttpConnection`. The full server lifecycle (Bonjour, pairing-mode toggle,
/// sleep/wake) is assembled in phase 22-7; this type is the transport core it
/// composes.
public actor SyncListener {
    /// The Bonjour service type for Phone Sync (sync-protocol.md section 1).
    static let serviceType = "_bocansync._tcp"

    private let identity: ServerIdentity
    private let router: Router
    private let trusted: TrustedFingerprintSet
    private let pairingMode: @Sendable () -> Bool
    private let serviceName: @Sendable () -> String
    private let log = AppLogger.make(.sync)
    private let queue = DispatchQueue(label: "io.cloudcauldron.bocan.sync.listener")
    private var listener: NWListener?
    private var advertise = false
    private var fingerprint: String?
    /// A browser started alongside advertising purely to raise the macOS Local Network
    /// permission prompt. On macOS 15 and later a sandboxed server that only advertises is
    /// never prompted (the prompt fires on browsing or outbound local access), so without
    /// this the Bonjour advertisement is silently suppressed and no phone can discover the
    /// Mac. Browsing triggers the prompt; once the user allows it, the advertisement is
    /// published. Its results are ignored.
    private var permissionBrowser: NWBrowser?

    init(
        identity: ServerIdentity,
        router: Router,
        trusted: TrustedFingerprintSet,
        pairingMode: @escaping @Sendable () -> Bool,
        serviceName: @escaping @Sendable () -> String = { Host.current().localizedName ?? "Bocan" }
    ) {
        self.identity = identity
        self.router = router
        self.trusted = trusted
        self.pairingMode = pairingMode
        self.serviceName = serviceName
    }

    /// Starts the listener on `port` (an ephemeral port when `nil`) and returns
    /// the actual bound port. When `advertise` is true, the listener also
    /// advertises `_bocansync._tcp` over Bonjour.
    func start(port: UInt16? = nil, advertise: Bool = false) async throws -> UInt16 {
        let loaded = try await self.identity.load()
        self.fingerprint = loaded.fingerprint.hex
        self.advertise = advertise
        let trusted = self.trusted
        let isTrusted: @Sendable (String) -> Bool = { trusted.contains($0) }

        let tlsOptions = try TLSOptions.make(
            identity: loaded.secIdentity.value,
            pairingMode: self.pairingMode,
            isTrusted: isTrusted
        )
        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true

        let endpointPort: NWEndpoint.Port = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        let listener = try NWListener(using: parameters, on: endpointPort)
        self.listener = listener
        if advertise, let service = self.makeService() {
            listener.service = service
        }

        let router = self.router
        let pairingMode = self.pairingMode
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            let handler = HttpConnection(
                connection: connection,
                router: router,
                pairingMode: pairingMode,
                isTrusted: isTrusted
            )
            handler.start(queue: queue)
        }

        let boundPort = try await self.awaitReady(listener)
        if advertise {
            self.startPermissionBrowser()
        }
        return boundPort
    }

    func stop() {
        self.permissionBrowser?.cancel()
        self.permissionBrowser = nil
        self.listener?.cancel()
        self.listener = nil
        self.advertise = false
    }

    /// Browse our own service type so macOS presents the Local Network permission prompt
    /// (see [permissionBrowser]). The browse results are intentionally unused: an
    /// advertise-only server is never prompted on its own, so this is what lets the
    /// Bonjour advertisement actually publish once the user allows access.
    private func startPermissionBrowser() {
        guard self.permissionBrowser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        let log = self.log
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log.debug("sync.localNetwork.browser.ready")
            case let .waiting(error):
                log.debug("sync.localNetwork.browser.waiting", ["error": String(reflecting: error)])
            case let .failed(error):
                log.error("sync.localNetwork.browser.failed", ["error": String(reflecting: error)])
            default:
                break
            }
        }
        browser.start(queue: self.queue)
        self.permissionBrowser = browser
    }

    /// Re-registers the Bonjour service with the current pairing-mode flag in the
    /// TXT record. Called whenever pairing mode toggles.
    func updatePairingMode(_: Bool) {
        guard self.advertise, let listener = self.listener, let service = self.makeService() else { return }
        listener.service = service
    }

    /// Re-advertises after a wake, when the listener may have dropped its service.
    func reAdvertise() {
        guard self.advertise, let listener = self.listener, let service = self.makeService() else { return }
        listener.service = service
    }

    private func makeService() -> NWListener.Service? {
        guard let fingerprint = self.fingerprint else { return nil }
        let txt = Self.txtRecord(fingerprint: fingerprint, pairingMode: self.pairingMode())
        return NWListener.Service(name: self.serviceName(), type: Self.serviceType, txtRecord: txt.data)
    }

    /// The Bonjour TXT record: `v=1`, `fp=<fingerprint>`, `pm=<0|1>`
    /// (sync-protocol.md section 1).
    static func txtRecord(fingerprint: String, pairingMode: Bool) -> NWTXTRecord {
        NWTXTRecord(["v": "1", "fp": fingerprint, "pm": pairingMode ? "1" : "0"])
    }

    private func awaitReady(_ listener: NWListener) async throws -> UInt16 {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let claim = { resumed.withLock { was -> Bool in
                    let alreadyResumed = was
                    was = true
                    return !alreadyResumed
                } }
                switch state {
                case .ready:
                    if claim() {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case let .failed(error):
                    if claim() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }
    }
}
