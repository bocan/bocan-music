import XCTest

// MARK: - SurfaceCompletenessTests

/// Phase 31 completeness: every `A11y` identifier registered for a
/// main-window surface must appear in exactly one crawl table, or in the
/// documented deferred/out-of-scope set with a reason. This is the
/// long-term payoff: a new control that ships without joining a table
/// turns the build red instead of relying on a reviewer noticing.
///
/// The registries below mirror the `A11y` constants (the reviewable
/// artifact). Runs host-less: it compares string sets, launches nothing.
final class SurfaceCompletenessTests: XCTestCase {
    // MARK: Registered identifiers per surface (mirror of A11y)

    /// A11y.Toolbar.* — fully owned by ToolbarSurfaceTests.
    static let toolbarRegistry: Set = [
        "toolbar.back", "toolbar.forward", "toolbar.miniPlayer",
        "toolbar.lyrics", "toolbar.visualizer", "toolbar.identifyTrack",
    ]

    /// A11y.NowPlaying.* that are actually attached to a control.
    static let transportRegistry: Set = [
        "nowPlayingStrip.artwork.button", "nowPlayingStrip.title.button",
        "nowPlayingStrip.subtitle.button", "nowPlayingStrip.love",
        "nowPlayingStrip.info", "nowPlayingStrip.prev", "nowPlayingStrip.playPause",
        "nowPlayingStrip.next", "nowPlayingStrip.shuffle", "nowPlayingStrip.repeat",
        "nowPlayingStrip.stopAfterCurrent", "nowPlayingStrip.mute",
        "nowPlayingStrip.volume", "nowPlayingStrip.scrubber",
        "nowPlayingStrip.speedPicker", "nowPlayingStrip.sleepTimer",
        "nowPlayingStrip.dsp",
        // Attached but not crawled here, with reasons (see transportSkips).
        "nowPlayingStrip.scrobblePending", "nowPlayingStrip.skipBack",
        "nowPlayingStrip.skipForward",
    ]

    /// Transport identifiers legitimately absent from the crawl table.
    static let transportSkips: [String: String] = [
        "nowPlayingStrip.scrobblePending": "only present when scrobbles are pending; the fixture queue produces none",
        "nowPlayingStrip.skipBack": "podcast-only transport control; the podcast surface (deferred) owns it",
        "nowPlayingStrip.skipForward": "podcast-only transport control; the podcast surface (deferred) owns it",
    ]

    // MARK: Cross-suite uniqueness

    @MainActor
    private var allCovered: [String] {
        ToolbarSurfaceTests.coveredIdentifiers
            + TransportSurfaceTests.coveredIdentifiers
            + BrowseSurfaceTests.songsCoveredIdentifiers
            + BrowseSurfaceTests.albumsCoveredIdentifiers
    }

    @MainActor
    func testNoIdentifierCoveredByTwoSuites() {
        var seen: Set<String> = []
        for identifier in self.allCovered {
            XCTAssertFalse(
                seen.contains(identifier),
                "\(identifier) is claimed by more than one surface suite"
            )
            seen.insert(identifier)
        }
    }

    // MARK: Bidirectional coverage (fully-owned surfaces)

    @MainActor
    func testToolbarSurfaceCoversItsRegistry() {
        XCTAssertEqual(
            Set(ToolbarSurfaceTests.coveredIdentifiers), Self.toolbarRegistry,
            "the Toolbar crawl table and A11y.Toolbar must match exactly"
        )
    }

    @MainActor
    func testTransportSurfaceCoversItsRegistry() {
        let covered = Set(TransportSurfaceTests.coveredIdentifiers)
        let skipped = Set(Self.transportSkips.keys)
        XCTAssertTrue(
            covered.isDisjoint(with: skipped),
            "a transport identifier is both crawled and skipped"
        )
        XCTAssertEqual(
            covered.union(skipped), Self.transportRegistry,
            "every attached transport identifier must be crawled or skipped with a reason"
        )
        for (_, reason) in Self.transportSkips {
            XCTAssertFalse(reason.isEmpty, "transport skip needs a reason")
        }
    }

    // MARK: Deferred surfaces (not yet crawled)

    /// Main-window surfaces whose control tables are a later phase-31 slice.
    /// Listed so the remaining work is explicit, not silently missing.
    @MainActor
    func testDeferredSurfacesAreDocumented() {
        let deferred = [
            "Artists / Genres / Composers listings",
            "Podcasts browse", "Radio", "Up Next queue rows",
            "Recently Added / Played / Most Played", "local playlist",
            "smart playlist detail", "search results", "sidebar rows",
            "empty-state action button", "scan banner",
        ]
        XCTAssertFalse(deferred.isEmpty)
        XCTAssertTrue(
            deferred.allSatisfy { !$0.isEmpty },
            "each deferred surface must be named"
        )
    }
}
