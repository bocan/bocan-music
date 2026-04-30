import Foundation

/// Errors thrown by the smart-playlist subsystem.
public enum SmartPlaylistError: Error, Sendable {
    /// The criteria tree contains a `group` with no children.
    case emptyGroup
    /// A `between` rule has `low > high`.
    case betweenRangeReversed
    /// `matchesRegex` value is not a valid ICU regular expression.
    case invalidRegex(String)
    /// The comparator is not valid for the field's data type.
    case incompatibleComparator(field: Field, comparator: Comparator)
    /// The value type does not match the field's expected type.
    case incompatibleValue(field: Field, value: Value)
    /// No playlist row found for `id`.
    case notFound(Int64)
    /// The playlist row is not a smart playlist.
    case notSmartPlaylist(Int64)
    /// JSON decode failure for persisted criteria.
    case decodeFailed(String)
    /// The criteria tree exceeds the maximum allowed group nesting depth.
    /// The UI caps interactive nesting at 3 levels; deeper trees can only
    /// arrive via hand-edited JSON or future migrations.
    case tooDeeplyNested(maxDepth: Int)
    /// A `memberOf` / `notMemberOf` rule references a playlist that is itself
    /// a smart playlist. Forbidden because evaluating the outer playlist would
    /// recursively compile the inner one and risk infinite recursion or
    /// silently empty results when in_playlist is implemented against
    /// `playlist_tracks` (which is empty for live smart playlists).
    case cannotReferenceSmartPlaylist(id: Int64)
    /// The criteria tree contains an `.invalid` sentinel — most often a rule
    /// referencing a field that this build no longer recognises. The playlist
    /// can still be read and rendered, but cannot be saved until the user
    /// removes the broken row.
    case invalidRule(reason: String)
}
