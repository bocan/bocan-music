import Foundation

// MARK: - LastFmCompatibleTransport

/// Shared HTTP + signing engine for Last.fm-compatible scrobble APIs
/// (Last.fm, Rocksky, …).
///
/// Handles request building, `api_sig` generation via `LastFmSignature`,
/// and maps Last.fm error codes to typed `ScrobbleError` values.
/// Callers assemble the method-specific parameters (including `api_key`
/// and, when required, `sk`) and call `signedPost` / `signedGet`.
struct LastFmCompatibleTransport {
    let http: HTTPClient
    let endpoint: URL

    // MARK: Convenience wrappers

    func signedPost(
        _ params: [String: String],
        sharedSecret: String,
        providerID: String
    ) async throws -> [String: Any] {
        try await self.send(params: params, method: "POST", sharedSecret: sharedSecret, providerID: providerID)
    }

    func signedGet(
        _ params: [String: String],
        sharedSecret: String,
        providerID: String
    ) async throws -> [String: Any] {
        try await self.send(params: params, method: "GET", sharedSecret: sharedSecret, providerID: providerID)
    }

    // MARK: Core

    func send(
        params: [String: String],
        method: String,
        sharedSecret: String,
        providerID: String
    ) async throws -> [String: Any] {
        var p = params
        p["api_sig"] = LastFmSignature.sign(p, secret: sharedSecret)
        p["format"] = "json"

        let request = try self.makeRequest(params: p, method: method, providerID: providerID)
        let (data, response) = try await self.http.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)

        if status >= 500 {
            let body = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw ScrobbleError.transient(
                provider: providerID,
                reason: "http \(status): \(body)",
                retryAfter: retryAfter
            )
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ScrobbleError.malformedResponse(provider: providerID, reason: "invalid json")
        }
        guard var json = parsed as? [String: Any] else {
            throw ScrobbleError.malformedResponse(provider: providerID, reason: "not an object")
        }

        if let errCode = json["error"] as? Int {
            let msg = (json["message"] as? String) ?? "error \(errCode)"
            // Codes per https://www.last.fm/api/errorcodes
            switch errCode {
            case 11, 16: // Service offline / temporarily unavailable
                throw ScrobbleError.transient(provider: providerID, reason: msg, retryAfter: retryAfter)
            case 29: // Rate limit exceeded
                throw ScrobbleError.transient(provider: providerID, reason: msg, retryAfter: retryAfter ?? 60)
            case 9: // Invalid session key — re-auth required
                throw ScrobbleError.invalidCredentials(provider: providerID)
            case 4, 13, 14, 17, 18, 22, 23: // Auth failed / token invalid / unauthorised
                throw ScrobbleError.invalidCredentials(provider: providerID)
            default:
                throw ScrobbleError.permanent(provider: providerID, reason: msg)
            }
        }

        // Status 2xx, no `error` key → success. Strip outer envelope if present.
        if let single = json.first, json.count == 1, let nested = single.value as? [String: Any] {
            json = nested
        }
        return json
    }

    // MARK: Request building

    private func makeRequest(params: [String: String], method: String, providerID: String) throws -> URLRequest {
        let body = self.formEncode(params)
        if method == "GET" {
            var components = URLComponents(url: self.endpoint, resolvingAgainstBaseURL: true)
                ?? URLComponents(string: self.endpoint.absoluteString)!
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components.url else {
                throw ScrobbleError.malformedResponse(provider: providerID, reason: "bad url")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            return req
        } else {
            var req = URLRequest(url: self.endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = Data(body.utf8)
            return req
        }
    }

    private func formEncode(_ params: [String: String]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { "\(self.escape($0.key))=\(self.escape($0.value))" }
            .joined(separator: "&")
    }

    private func escape(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
