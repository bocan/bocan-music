import Foundation

/// Mock API client for testing.
///
/// Usage:
/// ```swift
/// let mockClient = MockAPIClient()
/// mockClient.mockResponse(for: UsersEndpoint.self, response: [.mock])
///
/// let viewModel = UsersViewModel(apiClient: mockClient)
/// await viewModel.fetch()
///
/// XCTAssertEqual(viewModel.users.count, 1)
/// ```
final class MockAPIClient: APIClient, @unchecked Sendable {
    // MARK: - Storage

    private var responses: [String: Any] = [:]
    private var errors: [String: Error] = [:]
    private var requestHistory: [String] = []
    private var delay: TimeInterval = 0

    // MARK: - Configuration

    /// Set artificial delay for all requests (useful for testing loading states).
    func setDelay(_ delay: TimeInterval) {
        self.delay = delay
    }

    /// Mock a successful response for an endpoint type.
    func mockResponse<E: APIEndpoint>(for type: E.Type, response: E.Response) {
        self.responses[self.key(for: type)] = response
    }

    /// Mock an error for an endpoint type.
    func mockError(for type: (some APIEndpoint).Type, error: Error) {
        self.errors[self.key(for: type)] = error
    }

    /// Clear all mocks.
    func reset() {
        self.responses.removeAll()
        self.errors.removeAll()
        self.requestHistory.removeAll()
    }

    // MARK: - Request History

    /// Check if a specific endpoint was called.
    func wasCalled(_ type: (some APIEndpoint).Type) -> Bool {
        self.requestHistory.contains(self.key(for: type))
    }

    /// Number of times an endpoint was called.
    func callCount(_ type: (some APIEndpoint).Type) -> Int {
        self.requestHistory.count(where: { $0 == self.key(for: type) })
    }

    // MARK: - APIClient

    func request<E: APIEndpoint>(_ endpoint: E) async throws -> E.Response {
        let endpointKey = self.key(for: E.self)
        self.requestHistory.append(endpointKey)

        // Artificial delay
        if self.delay > 0 {
            try await Task.sleep(for: .seconds(self.delay))
        }

        // Check for mocked error
        if let error = errors[endpointKey] {
            throw error
        }

        // Check for mocked response
        guard let response = responses[endpointKey] as? E.Response else {
            throw NetworkError.noData
        }

        return response
    }

    // MARK: - Private

    private func key(for type: (some APIEndpoint).Type) -> String {
        String(describing: type)
    }
}

// MARK: - Convenience Extensions

extension MockAPIClient {
    /// Mock a network unavailable error.
    func mockNetworkUnavailable(for type: (some APIEndpoint).Type) {
        self.mockError(for: type, error: NetworkError.networkUnavailable)
    }

    /// Mock an unauthorized error.
    func mockUnauthorized(for type: (some APIEndpoint).Type) {
        self.mockError(for: type, error: NetworkError.unauthorized)
    }

    /// Mock a server error.
    func mockServerError(for type: (some APIEndpoint).Type, message: String = "Internal Server Error") {
        self.mockError(for: type, error: NetworkError.serverError(message))
    }
}
