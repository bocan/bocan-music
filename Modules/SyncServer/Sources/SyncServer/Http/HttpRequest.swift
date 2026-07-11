import Foundation

/// A parsed HTTP/1.1 request. Header field names are lowercased so lookups are
/// case-insensitive; the path is the raw path with the query split off.
struct HttpRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Case-insensitive header lookup.
    func header(_ name: String) -> String? {
        self.headers[name.lowercased()]
    }
}
