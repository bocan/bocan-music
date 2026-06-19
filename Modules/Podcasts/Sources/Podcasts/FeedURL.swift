import Foundation

/// Feed URL canonicalization. Single source of truth used by search dedupe (phase 21-3)
/// and subscription uniqueness (phase 21-4).
///
/// Rules per the overview contract:
///   1. Lowercase scheme and host.
///   2. Treat http and https as equivalent -- drop scheme from the key.
///   3. Drop a default port (:80, :443).
///   4. Drop trailing slash on the path.
///   5. Drop the URL fragment.
///   6. Keep path (case-sensitive) and query string verbatim.
///   7. Drop a leading "www." on the host.
public enum FeedURL {
    /// The dedupe/identity key: scheme-less, www-less, trailing-slash-less,
    /// fragment-less, default-port-less. Host lowercased; path and query kept.
    ///
    /// Example: both "https://www.Example.com:443/feed/?x=1#top" and
    /// "http://example.com/feed?x=1" produce "example.com/feed?x=1".
    public static func canonicalKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        // Normalize host: lowercase, drop www.
        var host = (components.host ?? "").lowercased()
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }

        // Drop default ports.
        let isHTTP = ["http", "https"].contains(components.scheme?.lowercased())
        if isHTTP, let port = components.port {
            if port == 80 || port == 443 {
                components.port = nil
            }
        }

        // Drop fragment (rule 5).
        components.fragment = nil

        // Build path: drop trailing slash (rule 4).
        var path = components.path
        if path.hasSuffix("/"), path.count > 1 {
            path = String(path.dropLast())
        }

        // Assemble: host + optional port + path + optional query.
        var key = host
        if let port = components.port {
            key += ":\(port)"
        }
        key += path
        if let query = components.percentEncodedQuery {
            key += "?\(query)"
        }
        return key
    }

    /// The absolute URL to store: https-preferred, no trailing slash, no fragment.
    /// Returns nil for non-http(s) inputs.
    public static func normalizedStorageURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }

        // Prefer https.
        components.scheme = "https"

        // Lowercase host.
        components.host = components.host?.lowercased()

        // Drop trailing slash on path.
        var path = components.path
        if path.hasSuffix("/"), path.count > 1 {
            path = String(path.dropLast())
        }
        components.path = path

        // Drop fragment.
        components.fragment = nil

        // Drop default ports.
        if let port = components.port, port == 80 || port == 443 {
            components.port = nil
        }

        return components.url
    }
}
