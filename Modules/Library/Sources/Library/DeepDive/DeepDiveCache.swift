import Foundation
import Observability

/// On-disk cache for Deep Dive reports: one JSON file per entity under
/// `Application Support/Bocan/DeepDive/`, kept for `ttl` and served stale
/// when the network is unavailable (#413).
public actor DeepDiveCache {
    public static let defaultTTL: TimeInterval = 7 * 24 * 3600

    private let root: URL
    private let ttl: TimeInterval
    private let log = AppLogger.make(.library)

    public init(root: URL? = nil, ttl: TimeInterval = DeepDiveCache.defaultTTL) {
        self.root = root ?? Self.defaultRoot
        self.ttl = ttl
    }

    private static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Bocan/DeepDive", isDirectory: true)
    }

    /// The cached value for `key`, with whether it is still within the TTL.
    public func load<T: Decodable & Sendable>(_ type: T.Type, key: String) -> (value: T, fresh: Bool)? {
        let url = self.fileURL(key)
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        return (value, Date().timeIntervalSince(modified) < self.ttl)
    }

    public func store(_ value: some Encodable & Sendable, key: String) {
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: self.fileURL(key), options: .atomic)
        } catch {
            self.log.warning("deepdive.cache.write_failed", ["key": key, "error": String(reflecting: error)])
        }
    }

    public func remove(key: String) {
        try? FileManager.default.removeItem(at: self.fileURL(key))
    }

    private func fileURL(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return self.root.appendingPathComponent(safe + ".json")
    }
}
