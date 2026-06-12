import AppKit
import Testing
@testable import UI

// MARK: - MainWindowTrackerTests

/// Lives at the UITests root (not ViewModelTests/) on purpose: these tests
/// create real `NSWindow`s, which need the SPM test environment, not the
/// host-less Xcode bundle.
///
/// Guards the hardened mini-player swap (issue #330 follow-up): `resolveWindow()`
/// must prefer the tracked reference, fall back to a search of `NSApp.windows`
/// when it is nil, and never return one of the auxiliary windows (which would
/// otherwise let the swap hide the mini player instead of the main window, or
/// spawn a duplicate main window on restore).
/// `.serialized`: every test mutates the `MainWindowTracker.shared` singleton and
/// reads the process-wide `NSApp.windows`, so they must not run concurrently.
@Suite("MainWindowTracker", .serialized)
@MainActor
struct MainWindowTrackerTests {
    /// Forces `canBecomeMain` so `resolveWindow`'s filter finds the test windows
    /// regardless of the test process's activation policy. A plain `NSWindow`
    /// reports `canBecomeMain == false` under the `.prohibited` policy a bare
    /// `swift test` process runs in, which made these tests pass only when an
    /// earlier test had promoted the app to a GUI state (the flakiness).
    private final class MainCapableWindow: NSWindow {
        override var canBecomeMain: Bool {
            true
        }
    }

    private func makeWindow(title: String = "", identifier: String? = nil) -> NSWindow {
        let win = MainCapableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.title = title
        if let identifier {
            win.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return win
    }

    @Test("resolveWindow prefers the tracked reference even when other windows exist")
    func prefersTrackedReference() {
        let original = MainWindowTracker.shared.window
        defer { MainWindowTracker.shared.window = original }

        let main = self.makeWindow(title: "Bòcan")
        let mini = self.makeWindow(title: "Mini Player", identifier: "mini")
        defer { main.close()
            mini.close()
        }

        MainWindowTracker.shared.window = main
        #expect(MainWindowTracker.shared.resolveWindow() === main)
    }

    @Test("resolveWindow never returns the mini player when falling back")
    func fallbackExcludesMini() {
        let original = MainWindowTracker.shared.window
        defer { MainWindowTracker.shared.window = original }

        let main = self.makeWindow(title: "Bòcan")
        let miniByID = self.makeWindow(title: "Floating", identifier: "mini")
        let miniByTitle = self.makeWindow(title: "Mini Player")
        defer { main.close()
            miniByID.close()
            miniByTitle.close()
        }

        MainWindowTracker.shared.window = nil
        let resolved = MainWindowTracker.shared.resolveWindow()

        // A main-capable, non-auxiliary window exists, so the fallback must find
        // one and it must not be either mini window.
        #expect(resolved != nil)
        #expect(resolved !== miniByID)
        #expect(resolved !== miniByTitle)
        #expect(resolved?.canBecomeMain == true)
    }

    @Test("resolveWindow excludes auxiliary windows by identifier")
    func fallbackExcludesAuxiliaryByIdentifier() {
        let original = MainWindowTracker.shared.window
        defer { MainWindowTracker.shared.window = original }

        let dsp = self.makeWindow(title: "Equaliser & DSP", identifier: "dsp")
        let about = self.makeWindow(title: "About", identifier: "about")
        defer { dsp.close()
            about.close()
        }

        MainWindowTracker.shared.window = nil
        let resolved = MainWindowTracker.shared.resolveWindow()

        #expect(resolved !== dsp)
        #expect(resolved !== about)
    }

    @Test("resolveWindow re-populates the tracker after a successful fallback")
    func fallbackRepopulatesTracker() {
        let original = MainWindowTracker.shared.window
        defer { MainWindowTracker.shared.window = original }

        let main = self.makeWindow(title: "Bòcan")
        defer { main.close() }

        MainWindowTracker.shared.window = nil
        let resolved = MainWindowTracker.shared.resolveWindow()
        // The weak reference should now hold whatever the fallback returned, so a
        // second call is cheap and identical.
        #expect(resolved != nil)
        #expect(MainWindowTracker.shared.window === resolved)
    }
}
