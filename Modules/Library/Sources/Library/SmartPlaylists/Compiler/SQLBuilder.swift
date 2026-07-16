import Foundation
import GRDB

// MARK: - CompiledCriteria

/// The output of compiling a `SmartCriterion` tree.
public struct CompiledCriteria: Sendable {
    /// Full `SELECT tracks.* FROM tracks … WHERE … ORDER BY … LIMIT …` statement.
    public let selectSQL: String
    /// `SELECT tracks.id …` variant used to construct an observation region
    /// with the same WHERE/JOIN/ORDER dependencies as `selectSQL`.
    public let observationRegionSQL: String
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

        // buildOrder can introduce joins (e.g. sorting by artist/album with no
        // matching rule), so it must run before the join clause is materialized.
        let orderSQL = Self.buildOrder(limitSort, seed: seed, joins: &joins)

        let joinSQL = joins.map(\.clause).sorted().joined(separator: "\n")

        let limitSQL = limitSort.limit.map { " LIMIT \($0)" } ?? ""

        let sql = """
        SELECT tracks.* FROM tracks
        \(joinSQL.isEmpty ? "" : joinSQL + "\n")WHERE tracks.disabled = 0 AND (\(whereClause))\(orderSQL)\(limitSQL)
        """

        let observationRegionSQL = """
        SELECT tracks.id FROM tracks
        \(joinSQL.isEmpty ? "" : joinSQL + "\n")WHERE tracks.disabled = 0 AND (\(whereClause))\(orderSQL)\(limitSQL)
        """

        return CompiledCriteria(
            selectSQL: sql,
            observationRegionSQL: observationRegionSQL,
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
            args.append(v.lowercased())
            return "LOWER(\(col)) = LOWER(?)"

        case .isNot:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append(v.lowercased())
            return "(\(col) IS NULL OR LOWER(\(col)) != LOWER(?))"

        case .contains:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append("%" + Self.escapeLike(v.lowercased()) + "%")
            return "LOWER(\(col)) LIKE LOWER(?) ESCAPE '\\'"

        case .doesNotContain:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append("%" + Self.escapeLike(v.lowercased()) + "%")
            return "(\(col) IS NULL OR LOWER(\(col)) NOT LIKE LOWER(?) ESCAPE '\\')"

        case .startsWith:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append(Self.escapeLike(v.lowercased()) + "%")
            return "LOWER(\(col)) LIKE LOWER(?) ESCAPE '\\'"

        case .endsWith:
            guard case let .text(v) = rule.value else { throw Self.valueError(rule) }
            args.append("%" + Self.escapeLike(v.lowercased()))
            return "LOWER(\(col)) LIKE LOWER(?) ESCAPE '\\'"

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
            // Match entire day: [start of day, start of next day).
            // Pin the Gregorian calendar to the device's current timezone so the
            // day boundary matches the user's local clock; Calendar.current can
            // silently change locale/era (e.g. th_TH Buddhist era) and produce
            // incorrect year-based arithmetic.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
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

        case let .unknown(raw):
            throw SmartPlaylistError.invalidRule(reason: "Unknown comparator \"\(raw)\"")
        }
    }

    // MARK: - ORDER BY

    private static func buildOrder(
        _ limitSort: LimitSort,
        seed: Int64,
        joins: inout Set<Join>
    ) -> String {
        let descriptors = limitSort.sortDescriptors.isEmpty
            ? [SmartSortDescriptor(key: .addedAt)]
            : limitSort.sortDescriptors

        // `random` is exclusive: if it is the primary key, use a stable
        // deterministic shuffle (hash(id XOR seed)) and ignore any tie-breakers.
        // The seed is stored on the playlist row and changes only on reshuffle.
        if descriptors.first?.key == .random {
            return " ORDER BY ((tracks.id * 6364136223846793005) + \(seed)) % 9223372036854775807 ASC"
        }

        var terms: [String] = []
        for descriptor in descriptors where descriptor.key != .random {
            let ref = Self.orderColumn(for: descriptor.key)
            if let join = ref.join { joins.insert(join) }
            let dir = descriptor.ascending ? "ASC" : "DESC"
            terms.append("\(ref.expression) \(dir)")
        }
        if terms.isEmpty {
            terms.append("tracks.added_at DESC")
        }
        return " ORDER BY " + terms.joined(separator: ", ")
    }

    /// Resolves a `SortKey` to its ORDER BY column expression and any JOIN it
    /// requires. Artist/album reuse `FieldDefinitions` so their JOIN clause is
    /// byte-identical to the one a matching rule would add and dedupes in the
    /// join set. `random` is handled by the caller and never routed here.
    private static func orderColumn(for key: SortKey) -> SQLColumnRef {
        switch key {
        case .title: SQLColumnRef(expression: "tracks.title")
        case .artist: FieldDefinitions.definition(for: .artist).columnRef
        case .album: FieldDefinitions.definition(for: .album).columnRef
        case .year: SQLColumnRef(expression: "tracks.year")
        case .trackNumber: SQLColumnRef(expression: "tracks.track_number")
        case .addedAt: SQLColumnRef(expression: "tracks.added_at")
        case .lastPlayedAt: SQLColumnRef(expression: "tracks.last_played_at")
        case .playCount: SQLColumnRef(expression: "tracks.play_count")
        case .rating: SQLColumnRef(expression: "tracks.rating")
        case .duration: SQLColumnRef(expression: "tracks.duration")
        case .bpm: SQLColumnRef(expression: "tracks.bpm")
        case .random: SQLColumnRef(expression: "tracks.added_at") // unreachable; guarded by caller
        }
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
