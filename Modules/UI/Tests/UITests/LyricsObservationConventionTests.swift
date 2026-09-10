import Combine
import Foundation
import Library
import Persistence
import Testing
@testable import UI

// MARK: - LyricsObservationConventionTests

/// #456: `TracksView` held the lyrics model as an `@EnvironmentObject` and
/// `BocanRootView` as an `@ObservedObject`, so both re-ran, with every child
/// that could not prove itself unchanged, on each synced lyric line, fetch and
/// offset change. Neither renders lyrics state: the tracks view captures the
/// model in two context-menu closures and reads one flag, the root hands the
/// model on and binds the pane toggle. Observation scope cannot be exercised
/// host-less, so these assert the wiring; the mirror test below checks the
/// one runtime assumption the root's toggle makes.
@Suite("Lyrics observation source conventions (#456)")
struct LyricsObservationConventionTests {
    private var moduleRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
    }

    private var repoRoot: URL {
        self.moduleRoot
            .deletingLastPathComponent() // Modules/
            .deletingLastPathComponent() // repo
    }

    private func source(_ relativePath: String, from root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Lines of code only: comments explaining the rule may name the wrapper.
    private func codeLines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test("TracksView reads the lyrics model as a plain environment value and its one flag by key")
    func tracksViewDoesNotObserveTheLyricsModel() throws {
        let source = try self.source("Sources/UI/Browse/TracksView.swift", from: self.moduleRoot)
        let code = self.codeLines(source)
        #expect(!code.contains { $0.contains("@EnvironmentObject") || $0.contains("@ObservedObject") })
        #expect(code.contains { $0.contains("@Environment(\\.lyricsViewModel) var lyricsViewModel") })
        #expect(code.contains { $0.contains("@AppStorage(\"lyrics.lrclibEnabled\") var lrclibEnabled") })

        let actions = try self.source("Sources/UI/Browse/TracksView+Actions.swift", from: self.moduleRoot)
        #expect(!actions.contains("lyricsEnv"))
        #expect(actions.contains("editLyrics: self.lyricsViewModel.map"))
        #expect(actions.contains("fetchLyricsFromLRClib: self.lrclibEnabled ? self.lyricsViewModel.map"))
    }

    @Test("BocanRootView holds the lyrics model as a plain reference and mirrors the pane key for the toggle")
    func rootHoldsAPlainReference() throws {
        let source = try self.source("Sources/UI/AppRoot/RootView.swift", from: self.moduleRoot)
        let code = self.codeLines(source)
        #expect(code.contains { $0.contains("private let lyricsVM: LyricsViewModel") })
        #expect(!code.contains { $0.contains("@ObservedObject private var lyricsVM") })
        #expect(code.contains { $0.contains("@AppStorage(\"lyrics.paneVisible\") private var lyricsPaneVisible") })
        #expect(code.contains { $0.contains("lyricsPaneVisible: self.$lyricsPaneVisible") })
        #expect(!code.contains { $0.contains("$lyricsVM.paneVisible") })
        #expect(code.contains { $0.contains(".environment(\\.lyricsViewModel, self.lyricsVM)") })
    }

    @Test("the mirrored keys are the model's own keys")
    func mirroredKeysMatchTheModel() throws {
        let model = try self.source("Sources/UI/Lyrics/LyricsViewModel.swift", from: self.moduleRoot)
        #expect(model.contains("@AppStorage(\"lyrics.paneVisible\") public var paneVisible"))
        #expect(model.contains("@AppStorage(\"lyrics.lrclibEnabled\") public private(set) var lrclibEnabled"))
        #expect(model.contains("@Entry var lyricsViewModel: LyricsViewModel?"))
    }

    @Test("no view in the module takes the lyrics model as an @EnvironmentObject, and the app no longer injects one")
    func noEnvironmentObjectSubscriberRemains() throws {
        let sources = self.moduleRoot.appendingPathComponent("Sources/UI")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in self.codeLines(text)
                where line.contains("@EnvironmentObject") && line.contains("LyricsViewModel") {
                offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "a view subscribes to the whole lyrics model: \(offenders)")

        let gate = try self.source("App/LaunchLoadingView.swift", from: self.repoRoot)
        #expect(!gate.contains(".environmentObject(graph.lyricsViewModel)"))
    }
}

// MARK: - LyricsPaneVisibleMirrorTests

/// The root's toolbar toggle writes `lyrics.paneVisible` through its own
/// `@AppStorage`, not through the model. The pane still decides its own
/// visibility from `LyricsViewModel.paneVisible`, so a write through the
/// defaults key must reach the model and publish, and a write from the model
/// (auto-show, the editor opening) must land in the key the root reads.
@Suite("Lyrics pane visibility mirror (#456)")
@MainActor
struct LyricsPaneVisibleMirrorTests {
    private static let key = "lyrics.paneVisible"

    @Test("a defaults write reaches the model and publishes; a model write lands in the defaults key")
    func paneVisibleRoundTrips() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.key)
        defer { defaults.removeObject(forKey: Self.key) }

        let db = try await Database(location: .inMemory)
        let vm = LyricsViewModel(service: LyricsService(database: db, fetcher: nil))
        #expect(!vm.paneVisible)

        var emissions = 0
        let sink = vm.objectWillChange.sink { emissions += 1 }
        defer { sink.cancel() }

        // The root's toggle: a write through the shared key.
        defaults.set(true, forKey: Self.key)
        #expect(vm.paneVisible, "the model reads the key the root wrote")
        #expect(emissions >= 1, "the pane must be told to redraw when the key changes under it")

        // The model's own writes (auto-show, openEditor) go the other way.
        vm.paneVisible = false
        #expect(!defaults.bool(forKey: Self.key), "the root's toolbar label follows the model's write")
    }
}
