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
}
