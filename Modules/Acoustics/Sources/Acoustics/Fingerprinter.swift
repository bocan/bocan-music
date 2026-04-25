import Foundation
import Observability

// MARK: - Fingerprinter

/// Computes Chromaprint acoustic fingerprints by invoking the bundled `fpcalc` binary.
///
/// `fpcalc` is Chromaprint's CLI tool. We use it instead of linking `libchromaprint`
/// directly because the pre-built fat binary avoids a complex build-script dependency
/// and produces a smaller Swift package footprint. The binary is code-signed and copied
/// into the app bundle via the "Copy Files" build phase.
public actor Fingerprinter {
    private let fpcalcURL: URL
    private let log = AppLogger.make(.network)

    /// - Parameter fpcalcURL: Absolute path to the `fpcalc` executable inside the app bundle.
    ///   Obtain via `Bundle.main.url(forResource: "fpcalc", withExtension: nil)`.
    public init(fpcalcURL: URL) {
        self.fpcalcURL = fpcalcURL
    }

    // MARK: - Public API

    /// Computes the Chromaprint fingerprint for the audio file at `url`.
    ///
    /// Analyses up to 120 seconds of audio (sufficient for AcoustID matching).
    /// The file must be accessible at the point of the call; resolve security-scoped
    /// bookmarks before invoking this method.
    ///
    /// - Parameter url: File URL for the audio file to analyse.
    /// - Returns: `(fingerprint, duration)` where `duration` is in seconds.
    /// - Throws: `AcousticsError.fpcalcFailed` if `fpcalc` exits with a non-zero code.
    public func fingerprint(url: URL) async throws -> (fingerprint: String, duration: Int) {
        let fpcalcURL = self.fpcalcURL
        self.log.debug("fingerprinter.start", ["path": url.lastPathComponent])
        let result = try await Task.detached(priority: .userInitiated) {
            // Task.detached is required here because waitUntilExit() blocks the
            // calling thread. Running off-actor keeps the main actor responsive.
            try Self.runFpcalc(at: fpcalcURL, fileURL: url)
        }.value
        self.log.debug("fingerprinter.done", ["duration": result.duration])
        return result
    }

    // MARK: - Private

    private static func runFpcalc(
        at fpcalcURL: URL,
        fileURL: URL
    ) throws -> (fingerprint: String, duration: Int) {
        let process = Process()
        process.executableURL = fpcalcURL
        process.arguments = ["-json", "-length", "120", fileURL.path(percentEncoded: false)]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let exitCode = process.terminationStatus
        guard exitCode == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw AcousticsError.fpcalcFailed(exitCode: exitCode, stderr: errStr)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return try self.parseFpcalcOutput(data)
    }

    static func parseFpcalcOutput(_ data: Data) throws -> (fingerprint: String, duration: Int) {
        let decoder = JSONDecoder()
        do {
            let output = try decoder.decode(FpcalcOutput.self, from: data)
            return (output.fingerprint, Int(output.duration.rounded()))
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw AcousticsError.invalidResponse(reason: "fpcalc JSON parse failed: \(raw.prefix(200))")
        }
    }
}
