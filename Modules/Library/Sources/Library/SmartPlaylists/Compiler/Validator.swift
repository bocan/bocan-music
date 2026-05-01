import Foundation

/// Validates a `SmartCriterion` tree before compilation or persistence.
public enum Validator {
    /// Maximum allowed group-nesting depth. The root group counts as depth 1.
    /// Mirrors the UI cap in `CriterionEditorView`, which hides the Add Group
    /// button once a group already sits at depth 2 (so children would be 3).
    /// Deeper trees can only arrive via hand-edited JSON or migrations.
    public static let maxGroupDepth = 3

    /// Validates the entire criteria tree, throwing the first error found.
    public static func validate(_ criterion: SmartCriterion) throws {
        try self.validateNode(criterion, depth: 1)
    }

    // MARK: - Private

    private static func validateNode(_ criterion: SmartCriterion, depth: Int) throws {
        switch criterion {
        case let .rule(rule):
            try Self.validateRule(rule)
        case let .invalid(reason):
            throw SmartPlaylistError.invalidRule(reason: reason)
        case let .group(_, children):
            guard !children.isEmpty else { throw SmartPlaylistError.emptyGroup }
            guard depth <= Self.maxGroupDepth else {
                throw SmartPlaylistError.tooDeeplyNested(maxDepth: Self.maxGroupDepth)
            }
            for child in children {
                try Self.validateNode(child, depth: depth + 1)
            }
        }
    }

    private static func validateRule(_ rule: SmartCriterion.Rule) throws {
        if case let .unknown(raw) = rule.field {
            throw SmartPlaylistError.invalidRule(reason: "Unknown field \"\(raw)\"")
        }
        if case let .unknown(raw) = rule.comparator {
            throw SmartPlaylistError.invalidRule(reason: "Unknown comparator \"\(raw)\"")
        }

        let def = FieldDefinitions.definition(for: rule.field)

        // Comparator must be allowed for this field.
        guard def.allowedComparators.contains(rule.comparator) else {
            throw SmartPlaylistError.incompatibleComparator(field: rule.field, comparator: rule.comparator)
        }

        // `between` requires a range value with low <= high.
        if rule.comparator == .between {
            guard case let .range(low, high) = rule.value else {
                throw SmartPlaylistError.incompatibleValue(field: rule.field, value: rule.value)
            }
            guard !Self.isDescending(low, high) else {
                throw SmartPlaylistError.betweenRangeReversed
            }
        }

        // `matchesRegex` value must compile.
        if rule.comparator == .matchesRegex {
            guard case let .text(pattern) = rule.value else {
                throw SmartPlaylistError.incompatibleValue(field: rule.field, value: rule.value)
            }
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw SmartPlaylistError.invalidRegex(pattern)
            }
        }

        // Membership comparators need a playlistRef or text.
        switch rule.comparator {
        case .memberOf, .notMemberOf:
            guard case .playlistRef = rule.value else {
                throw SmartPlaylistError.incompatibleValue(field: rule.field, value: rule.value)
            }
        case .pathUnder:
            guard case .text = rule.value else {
                throw SmartPlaylistError.incompatibleValue(field: rule.field, value: rule.value)
            }
        default:
            break
        }

        // Bool fields require bool comparators.
        if case .bool = def.dataType {
            switch rule.comparator {
            case .isTrue, .isFalse: break
            default:
                throw SmartPlaylistError.incompatibleComparator(field: rule.field, comparator: rule.comparator)
            }
        }
    }

    /// Returns `true` when `low` is strictly greater than `high` for ordered types.
    private static func isDescending(_ low: Value, _ high: Value) -> Bool {
        switch (low, high) {
        case let (.int(a), .int(b)): a > b
        case let (.double(a), .double(b)): a > b
        case let (.duration(a), .duration(b)): a > b
        case let (.date(a), .date(b)): a > b
        default: false
        }
    }
}
