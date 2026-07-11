import Foundation
import Observability
import os
import Persistence

/// A thread-safe, synchronously-readable set of trusted client-cert fingerprints.
///
/// The TLS verify block runs per handshake, off any actor, and must decide
/// synchronously whether to admit a connection. It captures this `Sendable`
/// object and calls `contains(_:)` without awaiting; `TrustedDevices` keeps the
/// set fresh from the database.
public final class TrustedFingerprintSet: Sendable {
    private let storage = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    public init() {}

    /// Whether `fingerprint` is currently trusted. Safe to call from any thread.
    public func contains(_ fingerprint: String) -> Bool {
        self.storage.withLock { $0.contains(fingerprint) }
    }

    func replace(with fingerprints: Set<String>) {
        self.storage.withLock { $0 = fingerprints }
    }

    func insert(_ fingerprint: String) {
        self.storage.withLock { _ = $0.insert(fingerprint) }
    }

    func remove(_ fingerprint: String) {
        self.storage.withLock { _ = $0.remove(fingerprint) }
    }
}

/// The set of phones paired for Phone Sync, backed by `trusted_devices`.
///
/// Owns an in-memory `TrustedFingerprintSet` snapshot the TLS verify block reads
/// synchronously, and keeps it fresh via a `ValueObservation` on the table so a
/// revoke (from this instance or elsewhere) takes effect on the next handshake
/// without a server restart.
public actor TrustedDevices {
    /// The synchronously-readable fingerprint snapshot for the TLS verify block.
    public nonisolated let fingerprints = TrustedFingerprintSet()

    private let repository: TrustedDeviceRepository
    private let log = AppLogger.make(.sync)
    private var observationTask: Task<Void, Never>?

    public init(repository: TrustedDeviceRepository) {
        self.repository = repository
    }

    /// Seeds the snapshot from the database and begins observing for changes.
    public func start() async throws {
        let devices = try await self.repository.all()
        self.fingerprints.replace(with: Set(devices.map(\.fingerprint)))

        let stream = await self.repository.observeAll()
        self.observationTask = Task { [fingerprints, log] in
            do {
                for try await devices in stream {
                    fingerprints.replace(with: Set(devices.map(\.fingerprint)))
                }
            } catch {
                log.warning("trusted.observe.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Stops observing. Call on server teardown.
    public func stop() {
        self.observationTask?.cancel()
        self.observationTask = nil
    }

    /// Trusts a newly paired device (persist + update the snapshot immediately).
    public func trust(_ device: TrustedDevice) async throws {
        try await self.repository.upsert(device)
        self.fingerprints.insert(device.fingerprint)
    }

    /// Revokes a device (persist + update the snapshot immediately).
    public func revoke(fingerprint: String) async throws {
        try await self.repository.delete(fingerprint: fingerprint)
        self.fingerprints.remove(fingerprint)
    }

    /// All trusted devices, most recently paired first (for the settings list).
    public func list() async throws -> [TrustedDevice] {
        try await self.repository.all()
    }
}
