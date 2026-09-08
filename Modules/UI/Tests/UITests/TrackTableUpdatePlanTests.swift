import Foundation
import Testing
@testable import UI

// MARK: - TrackTableUpdatePlanTests

/// #450 slice 2: `TrackTable.updateNSView` runs on every parent re-render.
/// The plan decides what per-row work is owed from the rows version, the ID
/// list, the highlight and the selection; identical inputs must owe nothing.
@Suite("TrackTableUpdatePlan")
struct TrackTableUpdatePlanTests {
    private typealias Plan = TrackTableUpdatePlan

    /// A memory of one earlier apply of version 3 with rows 1...3, track 2
    /// playing and row 1 selected.
    private let applied = Plan.Applied(rowsVersion: 3, ids: [1, 2, 3], nowPlayingID: .some(2), selection: [1])

    /// An ID closure that records whether the plan asked for the IDs.
    private final class IDProbe {
        var asked = false
        let ids: [Int64]

        init(_ ids: [Int64]) {
            self.ids = ids
        }

        func callAsFunction() -> [Int64] {
            self.asked = true
            return self.ids
        }
    }

    @Test("identical inputs owe no rows work, no reload, no selection walk, and never compute the IDs")
    func identicalInputsAreANoop() {
        let probe = IDProbe([1, 2, 3])
        let plan = Plan.make(rowsVersion: 3, ids: probe.callAsFunction, nowPlayingID: .some(2), selection: [1], applied: self.applied)

        #expect(plan.rowsWork == .unchanged)
        #expect(plan.ids == nil)
        #expect(plan.highlightReload.isEmpty)
        #expect(!plan.syncSelection)
        #expect(!probe.asked, "the ID walk must not run when the rows version is unchanged")
    }

    @Test("a new version with the same IDs reconfigures and walks the selection")
    func sameIDsNewVersionReconfigures() {
        let probe = IDProbe([1, 2, 3])
        let plan = Plan.make(rowsVersion: 4, ids: probe.callAsFunction, nowPlayingID: .some(2), selection: [1], applied: self.applied)

        #expect(plan.rowsWork == .reconfigure)
        #expect(plan.ids == [1, 2, 3])
        #expect(plan.highlightReload.isEmpty, "reconfigure covers the highlight rows itself")
        #expect(plan.syncSelection)
        #expect(probe.asked)
    }

    @Test("a new version with different IDs is structural")
    func differentIDsAreStructural() {
        let plan = Plan.make(rowsVersion: 4, ids: { [1, 2, 3, 4] }, nowPlayingID: .some(2), selection: [1], applied: self.applied)

        #expect(plan.rowsWork == .structural)
        #expect(plan.ids == [1, 2, 3, 4])
        #expect(plan.syncSelection)
    }

    @Test("the first apply with empty rows reconfigures, so the initial snapshot is not the empty one")
    func firstApplyWithEmptyRowsIsNotStructural() {
        // Matches the pre-#450 behaviour: an empty first call applied no
        // snapshot, so the later population did not animate as an update.
        let plan = Plan.make(rowsVersion: 0, ids: { [] }, nowPlayingID: nil, selection: [], applied: Plan.Applied())
        #expect(plan.rowsWork == .reconfigure)
        #expect(plan.syncSelection)
    }

    @Test("the first apply with rows is structural")
    func firstApplyWithRowsIsStructural() {
        let plan = Plan.make(rowsVersion: 0, ids: { [7, 8] }, nowPlayingID: nil, selection: [], applied: Plan.Applied())
        #expect(plan.rowsWork == .structural)
        #expect(plan.ids == [7, 8])
    }

    @Test("a highlight move with unchanged rows reloads only the outgoing and incoming rows")
    func highlightMoveReloadsTwoRows() {
        let probe = IDProbe([1, 2, 3])
        let plan = Plan.make(rowsVersion: 3, ids: probe.callAsFunction, nowPlayingID: .some(3), selection: [1], applied: self.applied)

        #expect(plan.rowsWork == .unchanged)
        #expect(plan.highlightReload == [2, 3])
        #expect(!plan.syncSelection)
        #expect(!probe.asked)
    }

    @Test("playback stopping reloads only the outgoing row")
    func highlightClearedReloadsOutgoingRow() {
        let plan = Plan.make(rowsVersion: 3, ids: { [1, 2, 3] }, nowPlayingID: .some(nil), selection: [1], applied: self.applied)
        #expect(plan.highlightReload == [2])
    }

    @Test("a selection change alone walks the selection and nothing else")
    func selectionChangeAloneSyncsSelection() {
        let probe = IDProbe([1, 2, 3])
        let plan = Plan.make(rowsVersion: 3, ids: probe.callAsFunction, nowPlayingID: .some(2), selection: [1, 3], applied: self.applied)

        #expect(plan.rowsWork == .unchanged)
        #expect(plan.highlightReload.isEmpty)
        #expect(plan.syncSelection)
        #expect(!probe.asked)
    }

    @Test("applied(after:) keeps the previous IDs when the plan did not compute them")
    func appliedKeepsIDsAcrossNoopUpdates() {
        let noop = Plan.make(rowsVersion: 3, ids: { [] }, nowPlayingID: .some(3), selection: [2], applied: self.applied)
        let next = noop.applied(after: self.applied, rowsVersion: 3, nowPlayingID: .some(3), selection: [2])

        #expect(next == Plan.Applied(rowsVersion: 3, ids: [1, 2, 3], nowPlayingID: .some(3), selection: [2]))

        let structural = Plan.make(rowsVersion: 4, ids: { [9] }, nowPlayingID: .some(3), selection: [2], applied: next)
        let after = structural.applied(after: next, rowsVersion: 4, nowPlayingID: .some(3), selection: [2])
        #expect(after.ids == [9])
        #expect(after.rowsVersion == 4)
    }
}
