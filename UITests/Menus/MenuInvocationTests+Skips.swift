import XCTest

// MARK: Skips

extension MenuInvocationTests {
    struct Skip {
        let menu: String
        let item: String
        let reason: String
    }

    static let skips: [Skip] = [
        Skip(
            menu: "Bòcan Music",
            item: "Check for Updates…",
            reason: "Sparkle cannot check in unsigned debug/E2E builds; the item is disabled"
        ),
        Skip(
            menu: "View",
            item: "View as",
            reason: "inert header row for the toggle pair below it"
        ),
        Skip(
            menu: "View",
            item: "as List",
            reason: "disabled off the collection listings; phase 31 exercises it with the Artists surface"
        ),
        Skip(
            menu: "View",
            item: "as Album Grid",
            reason: "disabled off the collection listings; phase 31 exercises it with the Artists surface"
        ),
        Skip(
            menu: "Track",
            item: "Identify Track…",
            reason: "opens a sheet that fires a live AcoustID lookup; hermetic network is phase 34"
        ),
        Skip(
            menu: "Track",
            item: "Reveal in Finder",
            reason: "activates Finder over the app; no in-app postcondition to assert"
        ),
        Skip(
            menu: "Track",
            item: "Fetch Lyrics from LRClib",
            reason: "hidden behind lyrics.lrclibEnabled, which the pass pins off to avoid live LRClib calls (phase 34)"
        ),
        Skip(
            menu: "Track",
            item: "Clear Lyrics",
            reason: "disabled: fixture tones carry no stored lyrics to clear"
        ),
        Skip(
            menu: "Tools",
            item: "Analyse Provenance…",
            reason: "only immediate feedback is a 2s toast (a SwiftUI overlay XCUITest does not surface); "
                + "its persistent result lives in Library Summary ▸ Audio Quality, exercised by the phase 32 window crawl"
        ),
    ]
}
