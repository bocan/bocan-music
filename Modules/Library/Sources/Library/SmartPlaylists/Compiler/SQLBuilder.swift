import Foundation
import GRDB

// MARK: - CompiledCriteria

/// The output of compiling a `SmartCriterion` tree.
public struct CompiledCriteria: Sendable {
    /// Full `SELECT tracks.* FROM tracks … WHERE … ORDER BY … LIMIT …` statement.
    public let selectSQL: String
    /// Bound arguments — no user-provided strings are ever interpolated into `selectSQL`.
    public let arguments: StatementArguments
    /// The set of JOINs included in the query (used to construct a `DatabaseRegion`).
    public let joins: Set<Join>
}

// MARK: - SQLBuilder

/// Compiles a validated `SmartCriterion` tree into a parameterised SQL query.
///
/// All user-supplied values are bound via `StatementArguments`.
/// No string interpolation of values is ever used.
public enum SQLBuilder {
    /// Compiles `criteria` with the given `limitSort` and `seed` into a `CompiledCriteria`.
    ///
    /// - Parameters:
    ///   - criteria: Pre-validated criteria tree.
    ///   - limitSort: Ordering and limit preferences.
    ///   - seed: Random seed stored in the playlist row (for stable `random` ordering).
    public static func compile(
        criteria: SmartCriterion,
        limitSort: LimitSort,
        seed: Int64 = 0
    ) throws -> CompiledCriteria {
        var args: [DatabaseValueConvertible?] = []
        var joins: Set<Join> = []

        let whereClause = try Self.buildWhere(criteria, args: &args, joins: &joins)

        let joinSQL = joins.map(\.clause).sorted().joined(separator: "\n")

        let orderSQL = Self.buildOrder(limitSort, seed: seed)
        let limitSQL = limitSort.limit.map { " LIMIT \($0)" } ?? ""

        let sql = """
        SELECT tracks.* FROM tracks
        \(joinSQL.isEmpty ? "" : joinSQL + "\n")WHERE tracks.disabled = 0 AND (\(whereClause))\(orderSQL)\(limitSQL)
        """

        return CompiledCriteria(
            selectSQL: sql,
            arguments: StatementArguments(args),
            joins: joins
        )
    }

    // MARK: - WHERE clause

    private static func buildWhere(
        _ criterion: SmartCriterion,
        args: inout [DatabaseValueConvertible?],
        joins: inout Set<Join>
    ) throws -> String {
        switch criterion {
        case let .rule(rule):
            return try Self.buildRule(rule, args: &args, joins: &joins)
        case let .invalid(reason):
            throw SmartPlaylistError.invalidRule(reason: reason)
        case let .group(op, children):
            let parts = try children.map { try Self.buildWhere($0, args: &args, joins: &joins) }
            let separator = op == .and ? " AND " : " OR "
            return "(" + parts.joined(separator: separator) + ")"
        }
    }

    // MARK: - Rule compilation

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func buildRule(
        _ rule: SmartCriterion.Rule,
        args: inout [DatabaseValueConvertible?],
        joins: inout Set<Join>
    ) throws -> String {
        let def = FieldDefinitions.definition(for: rule.field)
        if let join = def.columnRef.join { joins.insert(join) }
        let col = def.columnRef.expression

        switch rule.comparator {
        // ── Text ─────────────────────────────────────────────────────────────
        case .is:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append(v)
            return "\(col) = ? COLLATE NOCASE"

        case .isNot:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append(v)
            return "(\(col) IS NULL OR \(col) != ? COLLATE NOCASE)"

        case .contains:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append("%" + Self.escapeLike(v) + "%")
            return "\(col) LIKE ? ESCAPE '\\'"

        case .doesNotContain:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append("%" + Self.escapeLike(v) + "%")
            return "(\(col) IS NULL OR \(col) NOT LIKE ? ESCAPE '\\')"

        case .startsWith:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append(Self.escapeLike(v) + "%")
            return "\(col) LIKE ? ESCAPE '\\'"

        case .endsWith:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append("%" + Self.escapeLike(v))
            return "\(col) LIKE ? ESCAPE '\\'"

        case .matchesRegex:
            guard case let .text(pattern) = rule.value else { throw Self.valueError(rule) }
            args.append(pattern)
            return "\(col) REGEXP ?"

        case .isEmpty:
            return "(\(col) IS NULL OR \(col) = '')"

        case .isNotEmpty:
            return "(\(col) IS NOT NULL AND \(col) != '')"

        // ── Numeric / Duration ───────────────────────────────────────────────
        case .equalTo:
            try args.append(Self.numericArg(rule))
            return "\(col) = ?"

        case .notEqualTo:
            try args.append(Self.numericArg(rule))
            return "(\(col) IS NULL OR \(col) != ?)"

        case .lessThan:
            try args.append(Self.numericArg(rule))
            return "\(col) < ?"

        case .greaterThan:
            try args.append(Self.numericArg(rule))
            return "\(col) > ?"

        case .lessThanOrEqual:
            try args.append(Self.numericArg(rule))
            return "\(col) <= ?"

        case .greaterThanOrEqual:
            try args.append(Self.numericArg(rule))
            return "\(col) >= ?"

        case .between:
            guard case let .range(low, high) = rule.value else { throw Self.valueError(rule) }
            try args.append(Self.scalarArg(low, rule: rule))
            try args.append(Self.scalarArg(high, rule: rule))
            return "\(col) BETWEEN ? AND ?"

        case .isNull:
            return "\(col) IS NULL"

        case .isNotNull:
            return "\(col) IS NOT NULL"

        // ── Date ─────────────────────────────────────────────────────────────
        case .beforeDate:
            guard case let .date(d) = rule.value else { throw Self.valueError(rule) }
            args.append(Int64(d.timeIntervalSince1970))
            return "\(col) < ?"

        case .afterDate:
            guard case let .date(d) = rule.value else { throw Self.valueError(rule) }
            args.append(Int64(d.timeIntervalSince1970))
            return "\(col) > ?"

        case .onDate:
            guard case let .date(d) = rule.value else { throw Self.valueError(rule) }
            // Match entire day: [start of day, start of next day)
            let cal = Calendar.current
            let start = cal.startOfDay(for: d)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            args.append(Int64(start.timeIntervalSince1970))
            args.append(Int64(end.timeIntervalSince1970))
            return "\(col) >= ? AND \(col) < ?"

        case .inLastDays:
            guard case let .int(n) = rule.value else { throw Self.valueError(rule) }
            args.append(n)
            // Uses SQLite date functions so the cutoff is computed at query time.
            return "\(col) >= unixepoch('now', '-' || ? || ' days')"

        case .inLastMonths:
            guard case let .int(n) = rule.value else { throw Self.valueError(rule) }
            args.append(n)
            return "\(col) >= unixepoch('now', '-' || ? || ' months')"

        case .inLastYears:
            guard case let .int(n) = rule.value else { throw Self.valueError(rule) }
            args.append(n)
            return "\(col) >= unixepoch('now', '-' || ? || ' years')"

        // ── Boolean ──────────────────────────────────────────────────────────
        case .isTrue:
            if rule.field == .hasLyrics {
                return "(\(col) IS NOT NULL AND \(col) != '')"
            }
            if rule.field == .hasCoverArt || rule.field == .hasMusicBrainzReleaseID {
                return "\(col) IS NOT NULL"
            }
            return "\(col) = 1"

        case .isFalse:
            if rule.field == .hasLyrics {
                return "(\(col) IS NULL OR \(col) = '')"
            }
            if rule.field == .hasCoverArt || rule.field == .hasMusicBrainzReleaseID {
                return "\(col) IS NULL"
            }
            return "(\(col) IS NULL OR \(col) = 0)"

        // ── Membership ───────────────────────────────────────────────────────
        case .memberOf:
            guard case let .playlistRef(pid) = rule.value else { throw Self.valueError(rule) }
            let alias = "sp_pt_\(pid)"
            let join = Join(
                "INNER JOIN playlist_tracks AS \(alias) ON \(alias).track_id = tracks.id AND \(alias).playlist_id = \(pid)"
            )
            joins.insert(join)
            return "1 = 1" // the join itself filters membership

        case .notMemberOf:
            guard case let .playlistRef(pid) = rule.value else { throw Self.valueError(rule) }
            args.append(pid)
            return "tracks.id NOT IN (SELECT track_id FROM playlist_tracks WHERE playlist_id = ?)"

        case .pathUnder:
            guard case let .text(prefix) = rule.value else { throw Self.valueError(rule) }
            args.append(Self.escapeLike(prefix) + "%")
            return "\(col) LIKE ? ESCAPE '\\'"
        }
    }

    // MARK: - ORDER BY

    private static func buildOrder(_ limitSort: LimitSort, seed: Int64) -> String {
        let dir = limitSort.ascending ? "ASC" : "DESC"
        let orderExpr = switch limitSort.sortBy {
        case .title: "tracks.title \(dir)"
        case .artist: "artists.name \(dir)"
        case .album: "albums.title \(dir)"
        case .year: "tracks.year \(dir)"
        case .addedAt: "tracks.added_at \(dir)"
        case .lastPlayedAt: "tracks.last_played_at \(dir)"
        case .playCount: "tracks.play_count \(dir)"
        case .rating: "tracks.rating \(dir)"
        case .duration: "tracks.duration \(dir)"
        case .bpm: "tracks.bpm \(dir)"
        case .random:
            // Stable deterministic shuffle: hash(id XOR seed).
            // The seed is stored on the playlist row and changes only on manual refresh.
            "((tracks.id * 6364136223846793005) + \(seed)) % 9223372036854775807 ASC"
        }
        return " ORDER BY \(orderExpr)"
    }

    // MARK: - Helpers

    private static func numericArg(_ rule: SmartCriterion.Rule) throws -> DatabaseValueConvertible? {
        switch rule.value {
        case let .int(v): return v
        case let .double(v): return v
        case let .duration(v): return v
        default: throw self.valueError(rule)
        }
    }

    private static func scalarArg(_ v: Value, rule: SmartCriterion.Rule) throws -> DatabaseValueConvertible? {
        switch v {
        case let .int(x): return x
        case let .double(x): return x
        case let .duration(x): return x
        case let .date(x): return Int64(x.timeIntervalSince1970)
        default: throw self.valueError(rule)
        }
    }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func valueError(_ rule: SmartCriterion.Rule) -> SmartPlaylistError {
        SmartPlaylistError.incompatibleValue(field: rule.field, value: rule.value)
    }
}
