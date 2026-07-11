import Foundation
import GRDB
import Observability

/// Typed access to `trusted_devices`, the set of phones paired for Phone Sync.
///
/// The Phone Sync server reads this set on every TLS handshake (through an
/// in-memory snapshot it keeps fresh via `observeAll`), and writes it exactly
/// twice in the feature's life: on a successful pairing confirm (`upsert`) and
/// on a user revoke (`delete`).
public struct TrustedDeviceRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Read

    /// All paired devices, most recently paired first.
    public func all() async throws -> [TrustedDevice] {
        try await self.database.read { db in
            try TrustedDevice
                .order(Column("paired_at").desc)
                .fetchAll(db)
        }
    }

    /// Whether a device with `fingerprint` is currently trusted.
    public func contains(fingerprint: String) async throws -> Bool {
        try await self.database.read { db in
            try TrustedDevice.filter(key: fingerprint).fetchCount(db) > 0
        }
    }

    // MARK: - Write

    /// Inserts, or replaces on re-pair, a trusted device (keyed by fingerprint).
    public func upsert(_ device: TrustedDevice) async throws {
        try await self.database.write { db in
            try device.save(db)
        }
        self.log.debug("trusted_device.upsert", ["device": device.deviceName])
    }

    /// Removes a trusted device. Revocation takes effect on its next connection.
    public func delete(fingerprint: String) async throws {
        let removed = try await self.database.write { db in
            try TrustedDevice.deleteOne(db, key: fingerprint)
        }
        self.log.debug("trusted_device.delete", ["removed": removed])
    }

    // MARK: - Observation

    /// Streams the full trusted set immediately and again on every change, so the
    /// server's in-memory fingerprint snapshot stays current (a revoke propagates
    /// to the next handshake without a server restart).
    public func observeAll() async -> AsyncThrowingStream<[TrustedDevice], Error> {
        await self.database.observe { db in
            try TrustedDevice
                .order(Column("paired_at").desc)
                .fetchAll(db)
        }
    }
}
