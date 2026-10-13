import Foundation
import Testing
@testable import UI

/// One open or save panel at a time (#643). The panel itself cannot be driven
/// host-less, so the gate is tested on its own and a source-convention check
/// keeps every panel in the module behind it.
@Suite("PanelPresenter")
@MainActor
struct PanelPresenterTests {
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

    @Test("no source file in the module calls begin on a panel except PanelPresenter")
    func everyPanelGoesThroughThePresenter() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var presenterCalls = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            presenterCalls += text.components(separatedBy: "await PanelPresenter.present(").count - 1
            guard file.lastPathComponent != "PanelPresenter.swift" else {
                #expect(text.contains("self.gate.run("))
                continue
            }
            // `begin {` and `begin(completionHandler:` are how a panel is shown
            // without the gate; `beginSheetModal` (alerts) is a different call.
            if text.contains(".begin {") || text.contains(".begin(completionHandler") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "show the panel with PanelPresenter.present(_:) instead: \(offenders)")
        #expect(presenterCalls >= 12, "the pickers known on 2026-10-13; found \(presenterCalls)")
    }
}
