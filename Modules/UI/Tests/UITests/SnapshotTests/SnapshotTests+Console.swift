import Observability
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

// MARK: - Console snapshot seed data

private struct LogConsoleSeedEntry {
    let level: LogLevel
    let category: LogCategory
    let message: String
}

private let logConsoleSeedEntries: [LogConsoleSeedEntry] = [
    LogConsoleSeedEntry(level: .trace, category: .audio, message: "AVAudioEngine configured"),
    LogConsoleSeedEntry(level: .debug, category: .audio, message: "decoder.start [format=FLAC sampleRate=44100]"),
    LogConsoleSeedEntry(level: .info, category: .library, message: "Scan complete - 1843 tracks indexed"),
    LogConsoleSeedEntry(level: .notice, category: .network, message: "Subsonic server capability refreshed"),
    LogConsoleSeedEntry(level: .warning, category: .playback, message: "Gapless scheduler fell back to crossfade"),
    LogConsoleSeedEntry(level: .error, category: .scrobble, message: "Last.fm submission failed: HTTP 503"),
    LogConsoleSeedEntry(level: .fault, category: .persistence, message: "WAL checkpoint failed - database locked"),
    LogConsoleSeedEntry(level: .debug, category: .ui, message: "NowPlayingStrip re-layout triggered"),
    LogConsoleSeedEntry(level: .info, category: .metadata, message: "Cover art extracted [bytes=98304]"),
    LogConsoleSeedEntry(level: .warning, category: .audio, message: "Buffer underrun on render thread"),
]

extension UISnapshotTests {
    // MARK: - LogConsole Snapshots

    @Suite("LogConsole Snapshots")
    @MainActor
    struct LogConsoleSnapshotTests {
        private let size = CGSize(width: 900, height: 520)

        // MARK: - Helpers

        /// Builds a `LogConsoleViewModel` pre-loaded with a variety of entries.
        private func makePopulatedVM() -> LogConsoleViewModel {
            let store = LogStore(capacity: 200)
            // Use a fixed reference date so snapshot images are stable across runs.
            let base = Date(timeIntervalSinceReferenceDate: 735_000_000) // 2024-04-19 ~12:00 UTC
            for (offset, entry) in logConsoleSeedEntries.enumerated() {
                store.record(
                    level: entry.level,
                    category: entry.category,
                    message: entry.message,
                    at: base.addingTimeInterval(Double(offset))
                )
            }
            let (signals, _) = AsyncStream<Void>.makeStream()
            let vm = LogConsoleViewModel(store: store, flushSignals: signals)
            vm.start()
            return vm
        }

        private func makeEmptyVM() -> LogConsoleViewModel {
            let (signals, _) = AsyncStream<Void>.makeStream()
            let vm = LogConsoleViewModel(store: LogStore(capacity: 200), flushSignals: signals)
            vm.start()
            return vm
        }

        // MARK: - Populated

        @Test("LogConsole populated light mode")
        func populatedLight() {
            let vm = self.makePopulatedVM()
            let view = LogConsoleView(vm: vm).frame(width: 900, height: 520)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "log-console-populated-light"
            )
        }

        @Test("LogConsole populated dark mode")
        func populatedDark() {
            let vm = self.makePopulatedVM()
            let view = LogConsoleView(vm: vm)
                .frame(width: 900, height: 520)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "log-console-populated-dark"
            )
        }

        // MARK: - Empty

        @Test("LogConsole empty light mode")
        func emptyLight() {
            let vm = self.makeEmptyVM()
            let view = LogConsoleView(vm: vm).frame(width: 900, height: 520)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "log-console-empty-light"
            )
        }

        @Test("LogConsole empty dark mode")
        func emptyDark() {
            let vm = self.makeEmptyVM()
            let view = LogConsoleView(vm: vm)
                .frame(width: 900, height: 520)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "log-console-empty-dark"
            )
        }
    }
}
