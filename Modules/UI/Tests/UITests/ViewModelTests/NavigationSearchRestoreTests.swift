import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - NavigationSearchRestoreTests

/// Back/forward navigation restores the search query that was active at the
/// destination being returned to, so drilling into an album found via
/// type-to-search and pressing Esc (or the mouse back button) lands on the
/// still-filtered grid with the typed text intact — instead of the full,
/// unfiltered gallery the pre-restore behaviour produced.
@Suite("Navigation search-query restore")
struct NavigationSearchRestoreTests {
    @MainActor
    private func makeVM() async throws -> LibraryViewModel {
        let db = try await Database(location: .inMemory)
        return LibraryViewModel(database: db, engine: MockTransport())
    }

    @MainActor
    @Test("going back to a filtered grid restores its query")
    func backRestoresQuery() async throws {
        let vm = try await self.makeVM()
        await vm.selectDestination(.albums)
        vm.searchQuery = "ulrich"

        // Drilling into a detail page clears the search (unchanged behaviour).
        await vm.selectDestination(.album(7))
        #expect(vm.searchQuery.isEmpty)

        await vm.goBack()
        #expect(vm.selectedDestination == .albums)
        #expect(vm.searchQuery == "ulrich", "the filter the user left behind must come back")
    }

    @MainActor
    @Test("going forward into the detail page clears the query again")
    func forwardClearsAgain() async throws {
        let vm = try await self.makeVM()
        await vm.selectDestination(.albums)
        vm.searchQuery = "ulrich"
        await vm.selectDestination(.album(7))
        await vm.goBack()

        await vm.goForward()
        #expect(vm.selectedDestination == .album(7))
        #expect(vm.searchQuery.isEmpty, "detail pages stay unfiltered")

        await vm.goBack()
        #expect(vm.searchQuery == "ulrich", "and the round trip still restores")
    }

    @MainActor
    @Test("each history entry keeps its own query")
    func perEntryQueries() async throws {
        let vm = try await self.makeVM()
        await vm.selectDestination(.albums)
        vm.searchQuery = "ulrich"
        await vm.selectDestination(.artists)
        // Top-level to top-level keeps the live query (unchanged behaviour);
        // narrow it further here so the two entries differ.
        vm.searchQuery = "ulrich sch"
        await vm.selectDestination(.album(7))

        await vm.goBack()
        #expect(vm.selectedDestination == .artists)
        #expect(vm.searchQuery == "ulrich sch")

        await vm.goBack()
        #expect(vm.selectedDestination == .albums)
        #expect(vm.searchQuery == "ulrich")
    }

    @MainActor
    @Test("back from an unfiltered browse restores an empty query")
    func emptyQueryRestores() async throws {
        let vm = try await self.makeVM()
        await vm.selectDestination(.albums)
        await vm.selectDestination(.album(7))
        vm.searchQuery = ""

        await vm.goBack()
        #expect(vm.selectedDestination == .albums)
        #expect(vm.searchQuery.isEmpty)
    }
}
