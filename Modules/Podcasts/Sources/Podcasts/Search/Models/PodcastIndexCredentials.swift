import Foundation

/// Podcast Index API credentials.
///
/// When ``isConfigured`` is false (empty key or secret), ``PodcastSearchService``
/// skips the Podcast Index source and falls back to iTunes-only results. This is
/// a clean, expected path -- contributors without a key still get working search.
public struct PodcastIndexCredentials: Sendable {
    public var apiKey: String
    public var apiSecret: String
    public var isConfigured: Bool {
        !self.apiKey.isEmpty && !self.apiSecret.isEmpty
    }

    public init(apiKey: String, apiSecret: String) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }
}
