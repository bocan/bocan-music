import Observability

// MARK: - Recovered count lookups

/// The two count maps behind the subscribed grid.
///
/// Both recover to an empty map when the read fails, which is the right
/// recovery: the grid keeps its shows and loses only the numbers. What it must
/// not do is happen silently, so that a count of zero and a count that could
/// not be read stay tellable apart (`docs/audits/try-optional-audit.md`, class
/// (b), #491).
///
/// These sit in their own file because `PodcastsViewModel.swift` is already at
/// the module's 500-line limit.
extension PodcastsViewModel {
    /// Episode counts per show. An empty map shows every show as having no
    /// episodes, so a failed read must not pass for a genuine zero.
    func episodeCounts(_ library: any PodcastLibraryDataSource) async -> [Int64: Int] {
        do {
            return try await library.episodeCounts()
        } catch {
            self.log.warning("podcasts.episodeCounts.failed", ["error": String(reflecting: error)])
            return [:]
        }
    }

    /// Unread counts behind the grid badges. A failed read hides every badge,
    /// which looks exactly like a listener who is fully caught up.
    func unplayedCounts(_ library: any PodcastLibraryDataSource) async -> [Int64: Int] {
        do {
            return try await library.unplayedCounts()
        } catch {
            self.log.warning("podcasts.unplayedCounts.failed", ["error": String(reflecting: error)])
            return [:]
        }
    }
}
