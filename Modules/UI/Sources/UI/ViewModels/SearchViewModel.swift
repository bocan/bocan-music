import Foundation

// MARK: - SearchViewModel

/// Holds the active search query for the global toolbar search field.
///
/// `LibraryViewModel` observes `$query` via Combine (debounced 250 ms) and
/// re-loads the current destination filtered by the query.  This view-model
/// only needs to own the query string and the clear action.
@MainActor
public final class SearchViewModel: ObservableObject {
    // MARK: - Published state

    @Published public var query = ""

    // MARK: - Public API

    /// Clears the active query, returning all views to their unfiltered state.
    public func clear() {
        self.query = ""
    }
}
