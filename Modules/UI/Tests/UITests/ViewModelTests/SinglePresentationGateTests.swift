import Foundation
import Testing
@testable import UI

/// One picker panel at a time (#643). The panel itself cannot be driven
/// host-less, so the gate is tested on its own and a source-convention check
/// pins the library pickers to it.
@Suite("SinglePresentationGate")
@MainActor
struct SinglePresentationGateTests {
    @Test("a second request while the first is on screen is turned away and does not present")
    func secondRequestIsTurnedAway() async {
        let gate = SinglePresentationGate()
        var finishFirst: CheckedContinuation<String, Never>?
        var broughtToFront = 0
        var secondPresented = false

        let first = Task { @MainActor in
            await gate.run(busy: "busy") {
                await withCheckedContinuation { finishFirst = $0 }
            }
        }
        // Let the first request reach its suspension point.
        while finishFirst == nil {
            await Task.yield()
        }
        #expect(gate.isPresenting)

        let second = await gate.run(busy: "busy", whenBusy: { broughtToFront += 1 }, {
            secondPresented = true
            return "second"
        })

        #expect(second == "busy")
        #expect(!secondPresented)
        #expect(broughtToFront == 1)

        finishFirst?.resume(returning: "first")
        #expect(await first.value == "first")
        #expect(!gate.isPresenting)
    }

    @Test("the gate opens again when the presentation ends")
    func reopensAfterCompletion() async {
        let gate = SinglePresentationGate()

        let first = await gate.run(busy: 0) { 1 }
        let second = await gate.run(busy: 0) { 2 }

        #expect(first == 1)
        #expect(second == 2)
    }

    @Test("the library pickers present through the gated helper, not a bare panel.begin")
    func libraryPickersUseTheGate() throws {
        let viewModels = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/ViewModels")
        let scanning = try String(contentsOf: viewModels.appendingPathComponent("LibraryViewModel+Scanning.swift"), encoding: .utf8)
        #expect(scanning.components(separatedBy: "await Self.runOpenPanelAsync(panel)").count == 3, "folder and file pickers")
        #expect(!scanning.contains("panel.begin"))

        let helper = try String(contentsOf: viewModels.appendingPathComponent("LibraryViewModel+OpenPanel.swift"), encoding: .utf8)
        #expect(helper.contains("self.openPanelGate.run("))
    }
}
