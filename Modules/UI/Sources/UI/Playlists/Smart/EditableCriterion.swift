import Foundation
import Library

// MARK: - EditableCriterion

/// Value-type mirror of `SmartCriterion` that drives the rule builder UI.
///
/// Using a recursive enum directly with `@Binding` requires indirection
/// through a reference type or stable identity. We model each node as a
/// simple struct with an `id` so `ForEach` can track items stably.
public enum EditableCriterion: Identifiable, Equatable, Sendable {
    case rule(id: UUID, EditableRule)
    case group(id: UUID, op: LogicalOp, children: [Self])
    /// Mirrors `SmartCriterion.invalid` — a leaf produced when persisted
    /// criteria reference a field this build no longer knows about.
    /// The UI shows a placeholder row prompting the user to remove it.
    case invalid(id: UUID, reason: String)

    public var id: UUID {
        switch self {
        case let .rule(id, _):
            id

        case let .group(id, _, _):
            id

        case let .invalid(id, _):
            id
        }
    }

    // MARK: - Init from SmartCriterion

    public init(from criterion: SmartCriterion) {
        switch criterion {
        case let .rule(r):
            self = .rule(id: UUID(), EditableRule(from: r))

        case let .group(op, children):
            self = .group(id: UUID(), op: op, children: children.map { Self(from: $0) })

        case let .invalid(reason):
            self = .invalid(id: UUID(), reason: reason)
        }
    }

    // MARK: - Default

    public static func defaultRule() -> Self {
        .rule(id: UUID(), EditableRule())
    }

    public static func defaultGroup() -> Self {
        .group(id: UUID(), op: .and, children: [.defaultRule()])
    }

    // MARK: - Convert back

    public func toSmartCriterion() throws -> SmartCriterion {
        switch self {
        case let .rule(_, r):
            return try .rule(r.toRule())

        case let .group(_, op, children):
            if children.isEmpty {
                throw SmartPlaylistError.emptyGroup
            }
            return try .group(op, children.map { try $0.toSmartCriterion() })

        case let .invalid(_, reason):
            // Round-trips back to .invalid so the rest of the tree can still
            // be inspected. `Validator.validate` will reject the save with
            // SmartPlaylistError.invalidRule(reason:).
            return .invalid(reason: reason)
        }
    }
}

// MARK: - EditableRule

public struct EditableRule: Equatable, Sendable {
    public var field: Field
    public var comparator: Library.Comparator
    public var value: Value

    public init(field: Field = .title, comparator: Library.Comparator = .contains, value: Value = .text("")) {
        self.field = field
        self.comparator = comparator
        self.value = value
    }

    public init(from rule: SmartCriterion.Rule) {
        self.field = rule.field
        self.comparator = rule.comparator
        self.value = rule.value
    }

    public func toRule() throws -> SmartCriterion.Rule {
        SmartCriterion.Rule(field: self.field, comparator: self.comparator, value: self.value)
    }
}
