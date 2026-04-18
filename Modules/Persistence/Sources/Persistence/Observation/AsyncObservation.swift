import GRDB

/// Namespace for bridging GRDB `ValueObservation` to `AsyncThrowingStream`.
///
/// Use `AsyncObservation.sequence(in:value:)` when you need a typed async sequence
/// from outside the `Database` actor — for example, in a SwiftUI `@Observable` model.
///
/// ```swift
/// let stream = await AsyncObservation.sequence(in: db) { db in
///     try Track.fetchCount(db)
/// }
/// for try await count in stream {
///     print("Track count: \(count)")
/// }
/// ```
public enum AsyncObservation {
    /// Returns a stream that emits `value(db)` immediately and on every subsequent change.
    ///
    /// The stream terminates only on error or `Task` cancellation.
    /// Task cancellation propagates into the underlying GRDB observation.
    public static func sequence<T: Sendable>(
        in database: Database,
        value: @escaping @Sendable (GRDB.Database) throws -> T
    ) async -> AsyncThrowingStream<T, Error> {
        await database.observe(value: value)
    }
}
