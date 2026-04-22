import Foundation
import Persistence

// MARK: - BuiltInSmartPresets

/// Inserts the built-in smart playlist presets on first run.
///
/// Uses `smart_preset_key` as an idempotency key so presets are never
/// re-created if the user deletes them or if the app restarts.
public enum BuiltInSmartPresets {
    // MARK: - Seed

    /// Inserts any missing built-in presets into the library.
    ///
    /// Call this once after the app finishes its first scan, or lazily
    /// on `SmartPlaylistService.listAll()`.
    public static func seed(using service: SmartPlaylistService) async throws {
        let existing = try await service.listAll()
        let existingKeys = Set(existing.compactMap(\.smartPresetKey))

        for preset in Self.all where !existingKeys.contains(preset.key) {
            try await service.create(
                name: preset.name,
                criteria: preset.criteria,
                limitSort: preset.limitSort,
                presetKey: preset.key
            )
        }
    }

    // MARK: - Preset definitions

    struct Preset {
        let key: String
        let name: String
        let criteria: SmartCriterion
        let limitSort: LimitSort
    }

    static let all: [Preset] = [
        .init(
            key: "builtin.recently_added",
            name: "Recently Added",
            criteria: .rule(.init(field: .addedAt, comparator: .inLastDays, value: .int(30))),
            limitSort: LimitSort(sortBy: .addedAt, ascending: false)
        ),
        .init(
            key: "builtin.top25_most_played",
            name: "Top 25 Most Played",
            criteria: .rule(.init(field: .playCount, comparator: .greaterThan, value: .int(0))),
            limitSort: LimitSort(sortBy: .playCount, ascending: false, limit: 25)
        ),
        .init(
            key: "builtin.unrated",
            name: "Unrated",
            criteria: .rule(.init(field: .rating, comparator: .equalTo, value: .int(0))),
            limitSort: LimitSort(sortBy: .addedAt, ascending: false)
        ),
        .init(
            key: "builtin.loved",
            name: "Loved",
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .bool(true))),
            limitSort: LimitSort(sortBy: .addedAt, ascending: false)
        ),
        .init(
            key: "builtin.never_played",
            name: "Never Played",
            criteria: .rule(.init(field: .lastPlayedAt, comparator: .isNull, value: .null)),
            limitSort: LimitSort(sortBy: .addedAt, ascending: false)
        ),
        .init(
            key: "builtin.five_stars",
            name: "Five Stars",
            criteria: .rule(.init(field: .rating, comparator: .equalTo, value: .int(100))),
            limitSort: LimitSort(sortBy: .addedAt, ascending: false)
        ),
        .init(
            key: "builtin.high_bitrate",
            name: "High Bitrate",
            criteria: .rule(.init(field: .isLossless, comparator: .isTrue, value: .bool(true))),
            limitSort: LimitSort(sortBy: .addedAt, ascending: false)
        ),
    ]
}
