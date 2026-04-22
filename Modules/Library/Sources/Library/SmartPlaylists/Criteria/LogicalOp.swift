/// Logical operator used to combine multiple `SmartCriterion` children.
public enum LogicalOp: String, Sendable, Codable, Hashable, CaseIterable {
    case and
    case or
}
