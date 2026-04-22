/// All comparator operations a smart-playlist rule can apply.
///
/// Not every comparator is valid for every field type; use
/// `Field.allowedComparators` to retrieve the applicable subset.
public enum Comparator: String, Sendable, Codable, Hashable, CaseIterable {
    // MARK: - Text

    /// Exact case-insensitive match.
    case `is`
    /// Inverse of `is`.
    case isNot
    /// SQL `LIKE '%value%'`.
    case contains
    /// SQL `NOT LIKE '%value%'`.
    case doesNotContain
    /// SQL `LIKE 'value%'`.
    case startsWith
    /// SQL `LIKE '%value'`.
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
