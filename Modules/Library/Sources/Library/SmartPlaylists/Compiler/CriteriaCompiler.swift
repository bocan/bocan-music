import Foundation
import GRDB

/// High-level entry point: validate → compile → return `CompiledCriteria`.
public enum CriteriaCompiler {
    /// Validates `criteria` and compiles it into a parameterised SQL query.
    ///
    /// - Throws: `SmartPlaylistError` if validation fails.
    public static func compile(
        criteria: SmartCriterion,
        limitSort: LimitSort = LimitSort(),
        seed: Int64 = 0
    ) throws -> CompiledCriteria {
        try Validator.validate(criteria)
        return try SQLBuilder.compile(criteria: criteria, limitSort: limitSort, seed: seed)
    }
}
