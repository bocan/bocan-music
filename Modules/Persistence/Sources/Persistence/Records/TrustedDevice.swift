import Foundation
import GRDB

/// A phone paired for Phone Sync, stored in `trusted_devices`.
///
/// The primary key is the phone certificate's lowercase-hex SHA-256
/// `fingerprint`; after pairing this is the entire trust decision (a connection
/// whose client-cert fingerprint is absent here is refused at the TLS layer).
/// `certDER` is the pinned certificate itself. Re-pairing the same phone (same
/// certificate, so same fingerprint) upserts the row.
///
/// Conforms to `PersistableRecord` (not `MutablePersistableRecord`) because the
/// primary key is an explicit string, not an auto-increment id.
public struct TrustedDevice: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    // MARK: - Table

    public static let databaseTableName = "trusted_devices"

    // MARK: - Properties

    /// Lowercase-hex SHA-256 of the phone certificate DER (64 chars). Primary key.
    public var fingerprint: String
    /// The pinned client certificate, DER-encoded.
    public var certDER: Data
    /// Human-readable device name supplied during pairing.
    public var deviceName: String
    /// When the device was paired, as epoch seconds.
    public var pairedAt: Double

    // MARK: - Init

    public init(fingerprint: String, certDER: Data, deviceName: String, pairedAt: Double) {
        self.fingerprint = fingerprint
        self.certDER = certDER
        self.deviceName = deviceName
        self.pairedAt = pairedAt
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case fingerprint
        case certDER = "cert_der"
        case deviceName = "device_name"
        case pairedAt = "paired_at"
    }
}
