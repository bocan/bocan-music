import Foundation
import Testing
@testable import UI

// MARK: - L10nTests

/// Guards the localization foundation laid in #314.
///
/// Note on harness: pure SwiftPM (`swift test` / `make test-ui`) only *copies*
/// `Localizable.xcstrings`; it does not compile it into runtime `.strings` /
/// `.stringsdict`, so `String(localized:bundle:.module)` falls back to the key
/// there. The Xcode build *does* compile it (verified: the app bundle ships
/// `en.lproj/Localizable.stringsdict` with the correct plural rules). So rather
/// than assert runtime resolution — which is build-system dependent — these tests
/// validate the catalog *content* (the source of truth) and the wiring, both of
/// which are deterministic in either harness.
@Suite("Localization (L10n)")
struct L10nTests {
    private func catalog() throws -> [String: Any] {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["strings"] as? [String: Any]) ?? [:]
    }

    /// Extracts the `(one, other)` plural variation values for `key` from the catalog.
    private func plural(_ key: String, in strings: [String: Any]) -> (one: String, other: String)? {
        guard let entry = strings[key] as? [String: Any],
              let locs = entry["localizations"] as? [String: Any],
              let en = locs["en"] as? [String: Any],
              let variations = en["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any],
              let one = (plural["one"] as? [String: Any])?["stringUnit"] as? [String: Any],
              let other = (plural["other"] as? [String: Any])?["stringUnit"] as? [String: Any],
              let oneVal = one["value"] as? String,
              let otherVal = other["value"] as? String else { return nil }
        return (oneVal, otherVal)
    }

    @Test("Catalog contains the simple reference-screen keys (#314)")
    func catalogHasSimpleKeys() throws {
        let strings = try self.catalog()
        for key in ["Albums", "Various Artists", "Force Gapless Playback", "Add Music Folder"] {
            #expect(strings[key] != nil, "Catalog missing key: \(key)")
        }
    }

    @Test("'Play %lld Albums' pluralizes: one collapses to 'Play Album' (#314)")
    func playAlbumsPlural() throws {
        let variation = try #require(self.plural("Play %lld Albums", in: self.catalog()))
        #expect(variation.one == "Play Album")
        #expect(variation.other == "Play %lld Albums")
    }

    @Test("'%lld songs' pluralizes to a singular noun for one (#314)")
    func songsPlural() throws {
        let variation = try #require(self.plural("%lld songs", in: self.catalog()))
        #expect(variation.one == "%lld song")
        #expect(variation.other == "%lld songs")
    }

    @Test("Get Info / Remove context actions pluralize (#314)")
    func contextActionPlurals() throws {
        let strings = try self.catalog()
        let getInfo = try #require(self.plural("Get Info (%lld Albums)", in: strings))
        #expect(getInfo.one == "Get Info")
        let remove = try #require(self.plural("Remove %lld Albums from Library", in: strings))
        #expect(remove.one == "Remove Album from Library")
    }

    /// Module root (`Modules/UI/`) derived from this test file's path.
    private var moduleRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
    }

    @Test("UI package declares a default localization so the catalog is compiled (#314)")
    func packageDeclaresDefaultLocalization() throws {
        let url = self.moduleRoot.appendingPathComponent("Package.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("defaultLocalization:"), "Package.swift must set defaultLocalization for the catalog to compile")
    }

    @Test("Clear-queue alert message pluralizes (#314)")
    func clearQueuePlural() throws {
        let variation = try #require(
            self.plural("This removes the %lld tracks in your queue and stops playback.", in: self.catalog())
        )
        #expect(variation.one == "This removes the %lld track in your queue and stops playback.")
        #expect(variation.other == "This removes the %lld tracks in your queue and stops playback.")
    }

    @Test(
        "Phase 1 chrome routes copy through the localization helper (#314)",
        arguments: [
            "Sources/UI/Common/LoadingState.swift",
            "Sources/UI/AppRoot/RootView.swift",
            "Sources/UI/AppRoot/Sidebar.swift",
            "Sources/UI/AppRoot/SubsonicSidebarSection.swift",
            "Sources/UI/AppRoot/NowPlayingStrip.swift",
            "Sources/UI/AppRoot/DiagnosticsConsentBanner.swift",
            "Sources/UI/AppRoot/CrashRecoveryBanner.swift",
            "Sources/UI/Transport/SleepTimerMenu.swift",
            "Sources/UI/MiniPlayer/MiniPlayerView.swift",
            "Sources/UI/MenuBarExtra/MenuBarExtraScene.swift",
        ]
    )
    func phase1ChromeUsesHelper(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "\(relativePath) should localize copy via L10n.string")
    }

    @Test("AlbumsGridView routes copy through the localization helper (#314)")
    func referenceScreenUsesHelper() throws {
        let url = self.moduleRoot.appendingPathComponent("Sources/UI/Browse/AlbumsGridView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "AlbumsGridView should localize copy via L10n.string")
        // The old manual singular/plural ternaries must be gone (now driven by the catalog).
        #expect(
            !source.contains("\"Play \\(ids.count) Albums\" : \"Play Album\""),
            "Manual plural ternary should be replaced by a pluralized catalog key"
        )
    }
}
