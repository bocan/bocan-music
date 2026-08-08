import AppKit
import Testing
@testable import UI

// MARK: - EditMenuRouting tests (#379)

/// SPM-only suite (this directory is not globbed into the host-less Xcode
/// bundle): the tests instantiate AppKit views.
@Suite("EditMenuRouting")
@MainActor
struct EditMenuRoutingTests {
    @Test("a text view first responder routes to the editor")
    func textViewRoutesToEditor() {
        let editor = NSTextView(frame: .zero)
        #expect(EditMenuRouting.textEditor(from: editor) === editor)
    }

    @Test("non-text responders keep the browse meaning")
    func nonTextRoutesToTracks() {
        #expect(EditMenuRouting.textEditor(from: nil) == nil)
        #expect(EditMenuRouting.textEditor(from: NSView(frame: .zero)) == nil)
        #expect(EditMenuRouting.textEditor(from: NSTableView(frame: .zero)) == nil)
    }

    @Test("without a key window nothing forwards and tracks keep the command")
    func headlessDefaultsToTracks() {
        #expect(EditMenuRouting.textEditorIsActive == false)
        #expect(EditMenuRouting.forwardSelectAllToTextEditor() == false)
    }
}
