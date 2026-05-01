/// All comparator operations a smart-playlist rule can apply.
///
/// Not every comparator is valid for every field type; use
/// `Field.allowedComparators` to retrieve the applicable subset.
///
/// ## Case-insensitivity semantics (text comparators)
///
/// All text comparators (`is`, `isNot`, `contains`, `doesNotContain`,
/// `startsWith`, `endsWith`) are **Unicode case-insensitive**.
///
/// SQLite's built-in `COLLATE NOCASE` and `LIKE` operator are ASCII-only —
/// they will not match "Über" ↔ "über" or "Ελλάδα" ↔ "ελλάδα".
/// `SQLBuilder` therefore wraps both the column expression and the bound
/// parameter with SQLite's `LOWER()` scalar function, and also calls
/// `String.lowercased()` on the Swift side before binding:
///
/// ```sql
/// LOWER(tracks.title) LIKE LOWER(?) ESCAPE '\'
/// ```
///
/// `String.lowercased()` delegates to ICU on Apple platforms, giving correct
/// Unicode full-case folding for the device locale.  One known edge case:
/// German "ß" lowercases to "ß" (single character), but uppercases to "SS"
/// (two characters).  A search for "SS" will therefore **not** match a track
/// titled "Straße".  This is a fundamental Unicode limitation, not a bug.
public enum Comparator: String, Sendable, Codable, Hashable, CaseIterable {
    // MARK: - Text

    /// Exact Unicode case-insensitive match: `LOWER(col) = LOWER(?)`.
    case `is`
    /// Inverse of `is`: `LOWER(col) != LOWER(?)`.
    case isNot
    /// Unicode case-insensitive substring: `LOWER(col) LIKE LOWER('%value%')`.
    case contains
    /// Inverse of `contains`.
    case doesNotContain
    /// Unicode case-insensitive prefix: `LOWER(col) LIKE LOWER('value%')`.
    case startsWith
    /// Unicode case-insensitive suffix: `LOWER(col) LIKE LOWER('%value')`.
    case endsWith
    /// Custom `REGEXP` function (NSRegularExpression, unanchored).
    case matchesRegex
    /// Column `IS NULL` or `= ''`.
    case isEmpty
    /// Column `IS NOT NULL` and `≠ ''`.
    case isNotEmpty

    // MARK: - Numeric / Duration

    /// `= value`
    case equalTo
    /// `≠ value`
    case notEqualTo
    /// `< value`
    case lessThan
    /// `> value`
    case greaterThan
    /// `<= value`
    case lessThanOrEqual
    /// `>= value`
    case greaterThanOrEqual
    /// Inclusive range `[low, high]`.
    case between

    // MARK: - Null checks (numeric / date)

    case isNull
    case isNotNull

    // MARK: - Date-relative

    /// Track's date is within the last N days.
    case inLastDays
    /// Track's date is within the last N months.
    case inLastMonths
    /// Track's date is within the last N years.
    case inLastYears
    case beforeDate
    case afterDate
    case onDate

    // MARK: - Boolean

    case isTrue
    case isFalse

    // MARK: - Membership

    /// Track belongs to a given playlist.
    case memberOf
    /// Track does not belong to a given playlist.
    case notMemberOf
    /// Track's file URL begins with a path prefix.
    case pathUnder
}
