import AudioEngine
import Foundation
import Observability

// MARK: - SmokeCheck

/// The decode check the `smoketest` workflow runs inside a built app
/// (`Scripts/smoke-launch.sh`, #627).
///
/// Active only when `BOCAN_SMOKE_DECODE_LIST` names a text file with one
/// audio path or URL per line. The app then decodes each source to its end
/// through the normal decoder route, writes one report line per source to
/// `BOCAN_SMOKE_REPORT`, and exits: 0 when every source passed, 1 otherwise.
/// No output device is involved, so it runs on a headless runner. Nothing
/// here is reachable in normal use.
enum SmokeCheck {
    private static let log = AppLogger.make(.app)

    private static var listPath: String? {
        ProcessInfo.processInfo.environment["BOCAN_SMOKE_DECODE_LIST"]
    }

    private static var reportPath: String? {
        ProcessInfo.processInfo.environment["BOCAN_SMOKE_REPORT"]
    }

    /// Starts the check when the environment asks for it. Returns at once.
    static func startIfRequested() {
        guard let listPath, let reportPath else { return }
        Task.detached(priority: .userInitiated) {
            let code = await Self.run(listPath: listPath, reportPath: reportPath)
            exit(code)
        }
    }

    private static func run(listPath: String, reportPath: String) async -> Int32 {
        let sources: [String]
        do {
            sources = try String(contentsOfFile: listPath, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } catch {
            self.log.error("smoke.list.failed", ["error": String(reflecting: error)])
            return 2
        }
        let outcomes = await DecodeSmokeCheck.run(sources: sources)
        var lines = outcomes.map { outcome in
            [
                outcome.passed ? "PASS" : "FAIL",
                outcome.decoder,
                outcome.codec ?? "-",
                String(outcome.frames),
                String(format: "%.3f", outcome.peak),
                outcome.source,
                outcome.failure ?? "",
            ].joined(separator: "\t")
        }
        let allPassed = !outcomes.isEmpty && outcomes.allSatisfy(\.passed)
        lines.append(allPassed ? "RESULT\tok" : "RESULT\tfailed")
        do {
            let text = lines.joined(separator: "\n") + "\n"
            try text.write(toFile: reportPath, atomically: true, encoding: .utf8)
        } catch {
            self.log.error("smoke.report.failed", ["error": String(reflecting: error)])
            return 2
        }
        return allPassed ? 0 : 1
    }
}
