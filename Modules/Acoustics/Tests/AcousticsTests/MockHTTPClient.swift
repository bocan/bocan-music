import Foundation
@testable import Acoustics

// MARK: - MockHTTPClient

/// Test double for `HTTPClient` that returns a pre-configured response.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var responseData = Data()
    var statusCode = 200
    var error: Error?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let error {
            throw error
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (self.responseData, response)
    }
}

// MARK: - Fixture loader

extension Bundle {
    static func fixtureData(named name: String) -> Data {
        // SPM test bundles place .copy resources directly in the bundle's root.
        let url = Bundle.module.url(forResource: name, withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else {
            fatalError("Missing test fixture: \(name)")
        }
        return data
    }
}
