import Foundation

/// Field-level redaction rules.
/// Any field whose key (compared case-insensitively) appears in `sensitiveKeys`
/// will be replaced with `"<redacted>"` before the value reaches the log.
/// String values that look like URLs also have their sensitive query-parameter
/// values scrubbed, so a URL logged under a non-sensitive key (e.g. `"url"`)
/// cannot leak credentials embedded in its query string.
public enum Redaction {
    /// Lower-cased key names whose values must never appear in plain-text logs.
    public static let sensitiveKeys: Set = [
        "apikey", "token", "sessionkey", "password", "authorization",
        "cookie", "set-cookie", "secret", "refreshtoken", "accesstoken",
    ]

    /// Lower-cased URL query-parameter names whose values are scrubbed when
    /// they appear inside a logged URL string.
    public static let sensitiveQueryParams: Set = [
        "token", "salt", "api_key", "apikey", "password", "secret",
        "authorization", "access_token", "refresh_token", "sessionkey",
        "client_secret",
    ]

    /// Return a copy of `fields` with sensitive values replaced by `"<redacted>"`.
    public static func sanitize(_ fields: [String: Any]) -> [String: String] {
        fields.reduce(into: [:]) { out, kv in
            if self.sensitiveKeys.contains(kv.key.lowercased()) {
                out[kv.key] = "<redacted>"
            } else {
                out[kv.key] = self.scrubURLQueryParams(in: String(describing: kv.value))
            }
        }
    }

    /// If `str` looks like a URL (contains `?`), replaces the values of any
    /// query parameters whose names are in `sensitiveQueryParams` with `<redacted>`.
    /// Uses direct string manipulation to avoid percent-encoding the placeholder.
    static func scrubURLQueryParams(in str: String) -> String {
        guard let queryIdx = str.firstIndex(of: "?") else { return str }
        let base = String(str[str.startIndex ..< queryIdx])
        let query = String(str[str.index(after: queryIdx)...])
        let scrubbed = query.components(separatedBy: "&").map { pair -> String in
            let kv = pair.components(separatedBy: "=")
            guard kv.count >= 2,
                  self.sensitiveQueryParams.contains(kv[0].lowercased()) else { return pair }
            return "\(kv[0])=<redacted>"
        }
        return base + "?" + scrubbed.joined(separator: "&")
    }
}
