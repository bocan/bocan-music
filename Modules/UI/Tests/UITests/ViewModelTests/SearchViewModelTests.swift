import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - SearchViewModelTests

// Search is handled inline by LibraryViewModel.searchQuery (no dedicated
// SearchViewModel yet). These are source-convention checks over that subscription.

@Suite("SearchViewModel Tests")
struct SearchViewModelTests {
    private var libraryViewModelSource: String {
        get throws {
            let url = URL(filePath: #filePath)
                .deletingLastPathComponent() // ViewModelTests/
                .deletingLastPathComponent() // UITests/
                .deletingLastPathComponent() // Tests/
                .deletingLastPathComponent() // Modules/UI/
                .appendingPathComponent("Sources/UI/ViewModels/LibraryViewModel.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test("The search-query subscription drops its initial emission")
    func searchSubscriptionDropsInitialEmission() throws {
        let source = try self.libraryViewModelSource
        // @Published emits its current value on subscribe; without dropFirst the
        // empty initial query fired a full loadCurrentDestination() during launch.
        // dropFirst must come before the debounce so only real changes reload.
        guard let subRange = source.range(of: "self.$searchQuery") else {
            Issue.record("makeSearchQuerySubscription must subscribe to $searchQuery")
            return
        }
        let chain = source[subRange.upperBound...]
        let dropFirst = chain.range(of: ".dropFirst()")
        let debounce = chain.range(of: ".debounce(")
        #expect(dropFirst != nil, "the search subscription must call .dropFirst()")
        if let dropFirst, let debounce {
            #expect(
                dropFirst.lowerBound < debounce.lowerBound,
                ".dropFirst() must precede .debounce() in the search subscription"
            )
        }
    }
}
