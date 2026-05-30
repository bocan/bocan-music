import Foundation
import Testing
@testable import UI

// MARK: - DynamicTypeTests

/// Verifies that Bòcan respects macOS Dynamic Type by using semantic font
/// styles instead of hard-coded point sizes throughout the UI module.
///
/// These are source-convention tests: they read the compiled source tree and
/// fail if a hardcoded `Font.system(size:)` or `NSFont.systemFont(ofSize:)` /
/// `NSFont.boldSystemFont(ofSize:)` call is introduced.  Fast and zero-cost at
/// runtime; no AppKit/SwiftUI rendering required.
@Suite("Dynamic Type — semantic fonts")
struct DynamicTypeTests {
    // MARK: Helpers

    /// Root of the UI package Sources directory, derived from the path of this
    /// test file at compile time so it works regardless of working directory.
    private var uiSourcesURL: URL {
        // #filePath: .../Modules/UI/Tests/UITests/ViewModelTests/DynamicTypeTests.swift
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    /// Returns the combined Swift source of every `.swift` file under `url`.
    private func allSwiftSource(under url: URL) throws -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }
        var combined = ""
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            combined += (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
        return combined
    }

    // MARK: Typography.swift uses only semantic styles

    @Test("Typography.swift contains no hardcoded Font.system(size:) calls")
    func typographyUsesSemanticStyles() throws {
        let typographyURL = self.uiSourcesURL.appendingPathComponent("Theme/Typography.swift")
        let source = try String(contentsOf: typographyURL, encoding: .utf8)
        #expect(
            !source.contains("Font.system(size:"),
            "Typography.swift must not use hardcoded point sizes"
        )
    }

    // MARK: No hardcoded SwiftUI font sizes across the whole UI module

    @Test("UI module contains no Font.system(size:) calls")
    func noHardcodedSwiftUIFontSizes() throws {
        let source = try allSwiftSource(under: uiSourcesURL)
        #expect(
            !source.contains("Font.system(size:"),
            "All SwiftUI font sizes must use semantic TextStyle variants, not raw point sizes"
        )
    }

    // MARK: Transport / mini-player fonts scale with Dynamic Type (#299)

    /// Transport, mini-player, and menu-bar surfaces used fixed `.font(.system(size:))`
    /// glyphs and labels that ignored the user's text-size preference. They now route
    /// through `.scaledSystemFont(...)`, which scales via `@ScaledMetric`. Guard against
    /// regressions in exactly these files.
    private static let dynamicTypeScopedFiles = [
        "AppRoot/NowPlayingStrip.swift",
        "Transport/SpeedPickerView.swift",
        "Transport/SleepTimerMenu.swift",
        "MiniPlayer/MiniPlayerCompact.swift",
        "MiniPlayer/MiniPlayerSquare.swift",
        "MiniPlayer/MiniPlayerView.swift",
        "MiniPlayer/MiniPlayerVisualizer.swift",
        "MenuBarExtra/MenuBarExtraScene.swift",
    ]

    @Test("Transport and mini-player files no longer use fixed-size system fonts (#299)")
    func transportFilesUseScaledFonts() throws {
        for relativePath in Self.dynamicTypeScopedFiles {
            let url = self.uiSourcesURL.appendingPathComponent(relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(
                !source.contains(".font(.system(size:"),
                "\(relativePath) must use .scaledSystemFont(...) instead of fixed .font(.system(size:))"
            )
        }
    }

    @Test("ScaledSystemFont helper exists and uses @ScaledMetric")
    func scaledSystemFontHelperUsesScaledMetric() throws {
        let url = self.uiSourcesURL.appendingPathComponent("Theme/ScaledSystemFont.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("@ScaledMetric"),
            "scaledSystemFont must drive its size through @ScaledMetric so it honours Dynamic Type"
        )
    }

    // MARK: No hardcoded NSFont sizes in UI module

    @Test("UI module contains no NSFont.systemFont(ofSize:) calls")
    func noHardcodedNSFontSystemFont() throws {
        let source = try allSwiftSource(under: uiSourcesURL)
        #expect(
            !source.contains("NSFont.systemFont(ofSize:"),
            "NSFont sizes must use NSFont.preferredFont(forTextStyle:), not hardcoded ofSize:"
        )
    }

    @Test("UI module contains no NSFont.boldSystemFont(ofSize:) calls")
    func noHardcodedNSFontBoldSystemFont() throws {
        let source = try allSwiftSource(under: uiSourcesURL)
        #expect(
            !source.contains("boldSystemFont(ofSize:"),
            "NSFont bold sizes must use NSFontManager.convert(_:toHaveTrait:), not hardcoded ofSize:"
        )
    }

    // MARK: TrackTable uses preferredFont for Dynamic Type

    @Test("TrackTableCoordinator uses NSFont.preferredFont(forTextStyle:) for cell fonts")
    func trackTableCoordinatorUsesPreferredFont() throws {
        let url = self.uiSourcesURL.appendingPathComponent("Browse/TrackTableCoordinator.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("NSFont.preferredFont(forTextStyle:"),
            "TrackTableCoordinator must use NSFont.preferredFont(forTextStyle:) for scalable cell fonts"
        )
    }

    @Test("TrackTableCoordinator uses NSFont.preferredFont for body text cells")
    func trackTableCoordinatorBodyCellUsesPreferredFont() throws {
        let url = self.uiSourcesURL.appendingPathComponent("Browse/TrackTableCoordinator.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("NSFont.preferredFont(forTextStyle: .body)"),
            "TrackTableCoordinator must use NSFont.preferredFont(forTextStyle: .body) for scalable body text cells"
        )
    }

    // MARK: AccentColor dark variant (#301)

    @Test("AccentColor colorset has a dark-appearance variant for WCAG AA contrast")
    func accentColorHasDarkVariant() throws {
        // The colorset lives outside the Modules tree; navigate relative to this test file.
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // UI/
            .deletingLastPathComponent() // Modules/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/Assets.xcassets/AccentColor.colorset/Contents.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let colors = json?["colors"] as? [[String: Any]] ?? []
        let hasDark = colors.contains { entry in
            let appearances = entry["appearances"] as? [[String: Any]] ?? []
            return appearances.contains { $0["value"] as? String == "dark" }
        }
        #expect(hasDark, "AccentColor.colorset must have a dark-appearance variant so accent-as-text meets WCAG AA in dark mode")
    }

    // MARK: ShuffleCheckCell a11y label (#297)

    @Test("ShuffleCheckCell sets an accessibilityLabel on the checkbox")
    func shuffleCheckCellSetsAccessibilityLabel() throws {
        let url = self.uiSourcesURL.appendingPathComponent("Browse/TrackTableHelpers.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("setAccessibilityLabel") && source.contains("ShuffleCheckCell"),
            "ShuffleCheckCell must call setAccessibilityLabel so VoiceOver can identify the control"
        )
    }

    // MARK: LoveButtonCell uses preferredFont

    @Test("LoveButtonCell uses NSFont.preferredFont(forTextStyle:) for the heart glyph")
    func loveButtonCellUsesPreferredFont() throws {
        let url = self.uiSourcesURL.appendingPathComponent("Browse/TrackTableHelpers.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("NSFont.preferredFont(forTextStyle: .body)"),
            "LoveButtonCell must use NSFont.preferredFont(forTextStyle: .body) for the heart glyph"
        )
    }

    // MARK: Album grids use @ScaledMetric

    @Test("AlbumsGridView uses @ScaledMetric for adaptive grid minimum width")
    func albumsGridViewUsesScaledMetric() throws {
        let url = self.uiSourcesURL.appendingPathComponent("Browse/AlbumsGridView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("@ScaledMetric"),
            "AlbumsGridView must use @ScaledMetric so the grid adapts to the user's text size"
        )
    }

    @Test("ArtistDetailView uses @ScaledMetric for adaptive grid minimum width")
    func artistDetailViewUsesScaledMetric() throws {
        let url = self.uiSourcesURL.appendingPathComponent("Browse/ArtistsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("@ScaledMetric"),
            "ArtistDetailView must use @ScaledMetric so the album grid adapts to the user's text size"
        )
    }
}
