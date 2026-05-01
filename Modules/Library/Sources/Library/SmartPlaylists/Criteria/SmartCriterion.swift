import Observability

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
    /// A leaf produced when persisted criteria reference something this
    /// build cannot model (typically a field name removed in a later
    /// version). The playlist still loads and renders, but `Validator`
    /// refuses to save it until the user removes the broken row.
    case invalid(reason: String)

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

    // MARK: - Codable (manual, format-compatible with auto-synthesised form)

    private enum TopKey: String, CodingKey { case rule, group, invalid }
    private enum RuleAssoc: String, CodingKey { case _0 }
    private enum GroupAssoc: String, CodingKey { case _0, _1 }
    private enum InvalidAssoc: String, CodingKey { case reason }
    private static let log = AppLogger.make(.library)
    public static let newerVersionRuleMessage = "This rule was created in a newer version of Bòcan."

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TopKey.self)
        if container.contains(.invalid) {
            let inner = try container.nestedContainer(keyedBy: InvalidAssoc.self, forKey: .invalid)
            let reason = try inner.decode(String.self, forKey: .reason)
            self = .invalid(reason: reason)
            return
        }
        if container.contains(.rule) {
            let inner = try container.nestedContainer(keyedBy: RuleAssoc.self, forKey: .rule)
            do {
                let rule = try inner.decode(Rule.self, forKey: ._0)
                if let warning = Self.unknownRuleWarning(for: rule) {
                    Self.log.warning("smart.criteria.decode.unknownRule", ["warning": warning])
                    self = .invalid(reason: Self.newerVersionRuleMessage)
                } else {
                    self = .rule(rule)
                }
            } catch {
                // Future-proofing: a removed field or comparator must not
                // make the entire playlist undecodable. Surface a sentinel
                // so the UI can render an "invalid rule" placeholder.
                let reason = Self.lenientReason(from: inner) ?? "Unknown rule"
                Self.log.warning("smart.criteria.decode.ruleFailed", [
                    "reason": reason,
                    "error": String(reflecting: error),
                ])
                self = .invalid(reason: reason)
            }
            return
        }
        if container.contains(.group) {
            let inner = try container.nestedContainer(keyedBy: GroupAssoc.self, forKey: .group)
            let op = try inner.decode(LogicalOp.self, forKey: ._0)
            let children = try inner.decode([SmartCriterion].self, forKey: ._1)
            self = .group(op, children)
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: TopKey.rule,
            in: container,
            debugDescription: "Unknown SmartCriterion variant"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TopKey.self)
        switch self {
        case let .rule(rule):
            var inner = container.nestedContainer(keyedBy: RuleAssoc.self, forKey: .rule)
            try inner.encode(rule, forKey: ._0)
        case let .group(op, children):
            var inner = container.nestedContainer(keyedBy: GroupAssoc.self, forKey: .group)
            try inner.encode(op, forKey: ._0)
            try inner.encode(children, forKey: ._1)
        case let .invalid(reason):
            var inner = container.nestedContainer(keyedBy: InvalidAssoc.self, forKey: .invalid)
            try inner.encode(reason, forKey: .reason)
        }
    }

    /// Best-effort extraction of the offending field name when a Rule fails
    /// to decode strictly. Returns nil if the blob is too malformed to
    /// extract anything useful.
    private static func lenientReason(
        from container: KeyedDecodingContainer<RuleAssoc>
    ) -> String? {
        struct LenientRule: Decodable {
            let field: String?
            enum CodingKeys: String, CodingKey { case field }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.field = try? c.decode(String.self, forKey: .field)
            }
        }
        guard let lenient = try? container.decode(LenientRule.self, forKey: ._0),
              let field = lenient.field else { return nil }
        return "Unknown field \"\(field)\""
    }

    private static func unknownRuleWarning(for rule: Rule) -> String? {
        switch rule.field {
        case let .unknown(raw):
            return "Unknown field \"\(raw)\""
        default:
            break
        }
        switch rule.comparator {
        case let .unknown(raw):
            return "Unknown comparator \"\(raw)\""
        default:
            return nil
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
