import Foundation

/// The JSON form of a file's full TagLib property map, as stored in
/// `tracks.extended_tags`. The scanner and the tag editor both write the
/// column, so both encode through here and produce the same bytes.
enum ExtendedTagsJSON {
    /// Encodes `map` with sorted keys, so the column stays diff-stable across
    /// rescans of the same file. Returns `nil` for an empty map, which leaves
    /// the column NULL.
    static func encode(_ map: [String: [String]]) throws -> String? {
        guard !map.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(map)
        return String(data: data, encoding: .utf8)
    }
}
