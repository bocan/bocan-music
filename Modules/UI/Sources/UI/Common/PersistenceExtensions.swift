import Persistence

// MARK: - Track + Identifiable

/// Conformance so `Track` works with SwiftUI's `Table`, `ForEach`, and
/// `List` without any extra wrapper.  The `id` property is `Int64?` —
/// it is `nil` only for tracks that have not yet been inserted into the
/// database; every track returned from `TrackRepository` has a non-nil id.
extension Track: Identifiable {}

// MARK: - Album + Identifiable

/// Conformance so `Album` works with `ForEach`, `List`, and `Table`.
extension Album: Identifiable {}

// MARK: - Artist + Identifiable

/// Conformance so `Artist` works with `ForEach` and `List`.
extension Artist: Identifiable {}
