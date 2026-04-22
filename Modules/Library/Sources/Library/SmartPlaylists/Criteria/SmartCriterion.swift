/// A node in a smart-playlist criteria tree.
///
/// The recursive `group` case allows arbitrarily nested `AND` / `OR`
/// sub-expressions. Every `group` must contain at least one child —
/// `Validator` rejects empty groups before they reach the SQL compiler.
public indirect enum SmartCriterion: Sendable, Codable, Hashable {
    /// A single field / comparator / value leaf.
    case rule(Rule)
    /// A logical group of child criteria combined with `op`.
    case group(LogicalOp, [SmartCriterion])

    // MARK: - Rule

    public struct Rule: Sendable, Codable, Hashable {
        public let field: Field
        public let comparator: Comparator
        public let value: Value

        public init(field: Field, comparator: Comparator, value: Value) {
            self.field = field
            self.comparator = comparator
            self.value = value
        }
    }
}

// MARK: - Convenience constructors

public extension SmartCriterion {
    /// Wraps multiple rules in an `and` group.
    static func all(_ rules: [SmartCriterion]) -> SmartCriterion {
        .group(.and, rules)
    }

    /// Wraps multiple rules in an `or` group.
    static func any(_ rules: [SmartCriterion]) -> SmartCriterion {
        .group(.or, rules)
    }
}
