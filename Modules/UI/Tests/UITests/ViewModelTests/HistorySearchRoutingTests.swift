import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - HistorySearchRoutingTests

/// ADR-094 slice 2, contracts 4 to 7: the toolbar text is routed to
/// History's own query on History and to the library query everywhere
/// else; the two never mix; History always opens empty; and a visit to
/// History leaves the library query as it was.
@Suite("History search routing")
@MainActor
struct HistorySearchRoutingTests {
    private func makeViewModel() async throws -> LibraryViewModel {
        let db = try await Database(location: .inMemory)
        return LibraryViewModel(database: db, engine: MockTransport())
    }

    // MARK: Contract 4: independence

    @Test("On Songs, the toolbar text is the library query and History's stays empty")
    func onSongsRoutesToTheLibrary() async throws {
        let vm = try await self.makeViewModel()
        #expect(vm.selectedDestination != .history)

        vm.searchText = "bowen"

        #expect(vm.searchQuery == "bowen")
        #expect(vm.history.query.isEmpty)
        #expect(vm.searchText == "bowen")
    }

    @Test("On History, the toolbar text is History's query and the library's is untouched")
    func onHistoryRoutesToHistory() async throws {
        let vm = try await self.makeViewModel()
        vm.searchText = "bowen"
        await vm.selectDestination(.history)

        vm.searchText = "childers"

        #expect(vm.history.query == "childers")
        #expect(vm.searchQuery == "bowen", "the library query is not written on History")
        #expect(vm.searchText == "childers")
    }

    // MARK: Contracts 5 and 6: cleared on entry and on exit

    @Test("Entering History starts with an empty field")
    func enteringHistoryStartsEmpty() async throws {
        let vm = try await self.makeViewModel()
        vm.searchText = "bowen"

        await vm.selectDestination(.history)

        #expect(vm.searchText.isEmpty, "the field reads History's query, which is empty")
        #expect(vm.history.query.isEmpty)
        #expect(vm.history.debouncedQuery.isEmpty)
    }

    @Test("Leaving History discards its query, and it is not on the back stack")
    func leavingHistoryDiscards() async throws {
        let vm = try await self.makeViewModel()
        await vm.selectDestination(.history)
        vm.searchText = "childers"

        await vm.selectDestination(.songs)
        #expect(vm.history.query.isEmpty)
        #expect(vm.history.debouncedQuery.isEmpty)

        await vm.goBack()
        #expect(vm.selectedDestination == .history)
        #expect(vm.history.query.isEmpty, "coming back through history does not revive the term")
    }

    // MARK: Contract 7: the library query survives a visit

    @Test("A library filter is still there after going to History and back by the sidebar")
    func libraryQuerySurvivesASidebarVisit() async throws {
        let vm = try await self.makeViewModel()
        vm.searchText = "bowen"

        await vm.selectDestination(.history)
        await vm.selectDestination(.songs)

        #expect(vm.searchQuery == "bowen")
        #expect(vm.searchText == "bowen")
    }

    @Test("A library filter is restored after going to History and back with the back button")
    func libraryQuerySurvivesBackNavigation() async throws {
        let vm = try await self.makeViewModel()
        vm.searchText = "bowen"

        await vm.selectDestination(.history)
        await vm.goBack()

        #expect(vm.selectedDestination == .songs)
        #expect(vm.searchQuery == "bowen")
        #expect(vm.searchText == "bowen")
    }

    // MARK: Esc

    @Test("Esc on History clears History's query and leaves the library's alone")
    func escapeClearsHistoryQueryOnly() async throws {
        let vm = try await self.makeViewModel()
        vm.searchText = "bowen"
        await vm.selectDestination(.history)
        vm.searchText = "childers"

        #expect(vm.drillOutToParent() == true, "a non-empty History query is something to peel")
        #expect(vm.history.query.isEmpty)
        #expect(vm.searchQuery == "bowen")
        #expect(vm.drillOutToParent() == false, "nothing left to peel on a top-level row")
    }
}
