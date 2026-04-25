import Foundation
import Observability

// MARK: - PresetStore

/// Persists user-created EQ presets in UserDefaults.
///
/// Built-in presets are never mutated; this store owns only user presets.
/// Thread-safe: all mutations are serialised on a dedicated queue.
public final class PresetStore: @unchecked Sendable {
    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let log = AppLogger.make(.audio)

    // MARK: - State

    private let queue = DispatchQueue(label: "com.bocan.preset-store")
    private var _userPresets: [EQPreset] = []

    private static let defaultsKey = "io.cloudcauldron.bocan.userEQPresets"

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.queue.sync { self.loadFromDefaults() }
    }

    // MARK: - Public API

    /// All presets: built-ins first, then user presets.
    public var allPresets: [EQPreset] {
        self.queue.sync { BuiltInPresets.all + self._userPresets }
    }

    /// Only user-created presets.
    public var userPresets: [EQPreset] {
        self.queue.sync { self._userPresets }
    }

    /// Returns the preset with the given ID, or `nil` if not found.
    public func preset(forID id: EQPreset.ID) -> EQPreset? {
        self.allPresets.first { $0.id == id }
    }

    /// Saves a user preset (inserts or updates by ID). Built-ins are ignored.
    public func save(_ preset: EQPreset) {
        guard !preset.isBuiltIn else { return }
        self.queue.sync {
            if let idx = _userPresets.firstIndex(where: { $0.id == preset.id }) {
                self._userPresets[idx] = preset
            } else {
                self._userPresets.append(preset)
            }
            self.persist()
        }
        self.log.debug("preset.saved", ["id": preset.id, "name": preset.name])
    }

    /// Deletes a user preset by ID. No-op for built-ins.
    public func delete(id: EQPreset.ID) {
        self.queue.sync {
            self._userPresets.removeAll { $0.id == id }
            self.persist()
        }
        self.log.debug("preset.deleted", ["id": id])
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        do {
            self._userPresets = try JSONDecoder().decode([EQPreset].self, from: data)
        } catch {
            self.log.error("preset.load.failed", ["error": String(reflecting: error)])
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(self._userPresets)
            self.defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            self.log.error("preset.persist.failed", ["error": String(reflecting: error)])
        }
    }
}
