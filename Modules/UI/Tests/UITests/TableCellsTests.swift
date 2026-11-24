import AppKit
import Testing
@testable import UI

// MARK: - TableCellsTests

/// The cells the four song tables share (#695). These build real views, so
/// they live outside `ViewModelTests`: the host-less Xcode bundle cannot.
@MainActor
@Suite("Shared table cells")
struct TableCellsTests {
    private let tableView = NSTableView()

    // MARK: Text cell

    @Test("A new text cell carries its identifier and a tail-truncated label")
    func textCellLayout() throws {
        let id = NSUserInterfaceItemIdentifier("test.text")
        let cell = TableCells.text(id, in: self.tableView)
        #expect(cell.identifier == id)
        let field = try #require(cell.textField)
        #expect(field.superview === cell)
        #expect(field.lineBreakMode == .byTruncatingTail)
        #expect(field.cell?.truncatesLastVisibleLine == false)
    }

    @Test("The local songs table can ask for the last visible line to truncate")
    func textCellTruncatesLastLine() {
        let cell = TableCells.text(NSUserInterfaceItemIdentifier("test.text"), in: self.tableView, truncatesLastVisibleLine: true)
        #expect(cell.textField?.cell?.truncatesLastVisibleLine == true)
    }

    // MARK: Cover art cell

    @Test("A cover art cell carries the identifier its table reuses it by")
    func coverArtIdentifier() {
        let id = NSUserInterfaceItemIdentifier("sArtCell")
        #expect(TableCells.coverArt(id, in: self.tableView).identifier == id)
    }

    @Test("The cover is spoken as the title's artwork, or as no artwork")
    func coverArtLabel() {
        let cell = CoverArtTableCell(identifier: NSUserInterfaceItemIdentifier("test.art"))
        cell.configure(title: "Abbey Road", hasArt: true, load: nil)
        #expect(cell.accessibilityLabel() == "Abbey Road artwork")
        cell.configure(title: "Abbey Road", hasArt: false, load: nil)
        #expect(cell.accessibilityLabel() == "No artwork")
    }

    @Test("A reused cell shows the new row's cover, never a late one from the old row")
    func reuseCancelsTheOldLoad() async {
        let cell = CoverArtTableCell(identifier: NSUserInterfaceItemIdentifier("test.art"))
        let oldCover = NSImage(size: NSSize(width: 1, height: 1))
        let newCover = NSImage(size: NSSize(width: 2, height: 2))
        let (gate, open) = AsyncStream<Void>.makeStream()

        cell.configure(title: "Old", hasArt: true) {
            for await _ in gate {
                break
            }
            return oldCover
        }
        cell.configure(title: "New", hasArt: true) { newCover }
        await self.yield { cell.shownImage != nil }
        #expect(cell.shownImage === newCover)

        // The old load finishes after the reuse: the cell must ignore it.
        open.yield()
        open.finish()
        await self.yield { false }
        #expect(cell.shownImage === newCover)
    }

    @Test("Configuring again clears the cover at once")
    func configureClearsTheImage() async {
        let cell = CoverArtTableCell(identifier: NSUserInterfaceItemIdentifier("test.art"))
        let cover = NSImage(size: NSSize(width: 1, height: 1))
        cell.configure(title: "One", hasArt: true) { cover }
        await self.yield { cell.shownImage != nil }
        cell.configure(title: "Two", hasArt: false, load: nil)
        #expect(cell.shownImage == nil)
    }

    /// Lets main-actor tasks run, without a clock: up to 200 yields, or until
    /// `done` holds.
    private func yield(until done: () -> Bool) async {
        for _ in 0 ..< 200 where !done() {
            await Task.yield()
        }
    }
}
