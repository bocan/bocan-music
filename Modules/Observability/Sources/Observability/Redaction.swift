/// Field-level redaction rules.
/// Any field whose key (compared case-insensitively) appears in `sensitiveKeys`
/// will be replaced with `"<redacted>"` before the value reaches the log.
public enum Redaction {
    /// Lower-cased key names whose values must never appear in plain-text logs.
    public static let sensitiveKeys: Set = [
        "apikey", "token", "sessionkey", "password", "authorization",
        "cookie", "set-cookie", "secret", "refreshtoken", "accesstoken",
    ]

    /// Return a copy of `fields` with sensitive values replaced by `"<redacted>"`.
    public static func sanitize(_ fields: [String: Any]) -> [String: String] {
        fields.reduce(into: [:]) { out, kv in
            out[kv.key] = self.sensitiveKeys.contains(kv.key.lowercased())
                ? "<redacted>"
                : String(describing: kv.value)
        }
    }
}
