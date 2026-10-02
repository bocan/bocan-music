import Acoustics
import Foundation
import Testing
@testable import Library

// MARK: - Test doubles

/// Returns a fixed fingerprint string without invoking `fpcalc`.
struct StubFingerprinter: Fingerprintable {
    let fingerprint: String
    let duration: Int

    func fingerprint(url: URL) async throws -> (fingerprint: String, duration: Int) {
        (self.fingerprint, self.duration)
    }
}

/// Always throws to simulate a `fpcalc` crash.
struct FailingFingerprinter: Fingerprintable {
    func fingerprint(url: URL) async throws -> (fingerprint: String, duration: Int) {
        throw AcousticsError.fpcalcFailed(exitCode: 1, stderr: "stub failure")
    }
}

/// Minimal `HTTPClient` stub that returns pre-canned data.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    let responseData: Data
    let statusCode: Int

    init(responseData: Data, statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (self.responseData, response)
    }
}
