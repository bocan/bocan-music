import Foundation

/// The JSON form of a file's full TagLib property map, as stored in
/// `tracks.extended_tags`. The scanner and the tag editor both write the
/// column, so both encode through here and produce the same bytes.
///
/// NULL in the column means "this file's map was never read". A file read
/// with no tags at all stores `{}`, so the quick scan's one-time backfill
/// (#735) can tell the two apart and does not read a tagless file again on
/// every launch.
enum ExtendedTagsJSON {
    /// Encodes `map` with sorted keys, so the column stays diff-stable across
    /// rescans of the same file. An empty map encodes as `{}`.
    static func encode(_ map: [String: [String]]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(map)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                map,
                .init(codingPath: [], debugDescription: "JSONEncoder output is not UTF-8")
            )
        }
        return json
    }
}
