import Foundation
import Observability
import Persistence
import UI

// MARK: - SmokePlayback

/// The playback check the `smoketest` workflow runs inside a built app
/// (`Scripts/smoke-launch.sh`, #627).
///
/// Active only when `BOCAN_SMOKE_PLAY_DIR` names a folder of audio files and
/// `BOCAN_SMOKE_PLAY_REPORT` a file to write. The app then does what a
/// listener does: adds the folder to the library, plays each track through
/// the queue player with the main window on screen, waits until the position
/// moves and the play bar has its source facts, and holds each track for a
/// few seconds so the badge row lays out. It writes one report line per file
/// and exits. A trap while it runs ends the process before any report is
/// written, which the script reports as a failure.
///
/// This is the only smoke check that reaches the play bar. The decode check
/// (`SmokeCheck`) proves the libraries, and cannot see a view that fails.
@MainActor
enum SmokePlayback {
    private static let log = AppLogger.make(.app)

    private static let startTimeout: TimeInterval = 20
    private static let scanTimeout: TimeInterval = 90
    private static let dwell: TimeInterval = 3

    private static var directory: URL? {
        ProcessInfo.processInfo.environment["BOCAN_SMOKE_PLAY_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static var reportPath: String? {
        ProcessInfo.processInfo.environment["BOCAN_SMOKE_PLAY_REPORT"]
    }

    /// Runs the check and exits the process, when the environment asks for
    /// it. Returns at once otherwise.
    static func runIfRequested(_ lvm: LibraryViewModel) async {
        guard let directory, let reportPath else { return }
        let code = await Self.run(lvm, directory: directory, reportPath: reportPath)
        exit(code)
    }

    private static func run(_ lvm: LibraryViewModel, directory: URL, reportPath: String) async -> Int32 {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            self.log.error("smoke.play.list.failed", ["error": String(reflecting: error)])
            return 2
        }
        await lvm.addDroppedURLs([directory])
        let deadline = Date().addingTimeInterval(self.scanTimeout)
        while Date() < deadline {
            await lvm.loadCurrentDestination()
            if !lvm.isScanning, lvm.tracks.tracks.count >= names.count {
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        let library = lvm.tracks.tracks

        var lines: [String] = []
        var allPassed = !names.isEmpty
        for name in names {
            let line = await self.playOne(name, in: library, lvm: lvm)
            allPassed = allPassed && line.hasPrefix("PASS")
            lines.append(line)
        }
        lines.append(allPassed ? "RESULT\tok" : "RESULT\tfailed")
        do {
            let text = lines.joined(separator: "\n") + "\n"
            try text.write(toFile: reportPath, atomically: true, encoding: .utf8)
        } catch {
            self.log.error("smoke.play.report.failed", ["error": String(reflecting: error)])
            return 2
        }
        return allPassed ? 0 : 1
    }

    private static func playOne(_ name: String, in library: [Track], lvm: LibraryViewModel) async -> String {
        func fail(_ reason: String) -> String {
            ["FAIL", "-", "0", name, reason].joined(separator: "\t")
        }
        guard let index = library.firstIndex(where: { $0.fileURL.hasSuffix("/" + name) || $0.fileURL.hasSuffix(name) }) else {
            return fail("the scan did not take the file in")
        }
        lvm.playbackErrorMessage = nil
        await lvm.play(tracks: library, startingAt: index)

        let np = lvm.nowPlaying
        let deadline = Date().addingTimeInterval(self.startTimeout)
        while Date() < deadline {
            if np.isPlaying, np.position > 0.3, np.sourceFacts != nil {
                break
            }
            if let message = lvm.playbackErrorMessage {
                return fail("playback error: \(message)")
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard np.isPlaying else { return fail("not playing after \(Int(self.startTimeout)) s") }
        guard np.position > 0.3 else { return fail("position did not move (\(np.position) s)") }
        guard let facts = np.sourceFacts else { return fail("no source facts, so no badges") }

        // The badge row lays out once the facts are in; give it time to.
        try? await Task.sleep(for: .seconds(self.dwell))
        let position = String(format: "%.1f", np.position)
        return ["PASS", facts.codec ?? "-", position, name, ""].joined(separator: "\t")
    }
}
