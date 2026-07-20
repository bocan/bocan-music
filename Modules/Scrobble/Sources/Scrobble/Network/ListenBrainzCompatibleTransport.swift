import Foundation

// MARK: - ListenBrainzCompatibleTransport

/// Shared payload builder + HTTP engine for ListenBrainz-compatible scrobble
/// APIs (ListenBrainz, Rocksky, …).
///
/// The two providers speak the identical `submit-listens` wire protocol
/// (Bearer/`Token` auth, the same `track_metadata` JSON), so the payload
/// construction and the POST + status-to-`ScrobbleError` mapping live here once
/// rather than being copied per provider. Providers keep their own
/// method-level logic and logging (and their distinct `love`/auth surfaces) and
/// call `buildPayload` / `post` for the shared parts.
///
/// This mirrors `LastFmCompatibleTransport`, which does the same job for the
/// Last.fm-compatible family.
struct ListenBrainzCompatibleTransport {
    let http: HTTPClient
    let endpoint: URL

    // MARK: Payload

    /// Builds a ListenBrainz `submit-listens` body for `plays`.
    ///
    /// `listenType` is `"playing_now"` for a now-playing notification, `"single"`
    /// for a one-off submission, or `"import"` for a batch. `listened_at` is
    /// omitted for `"playing_now"` (the service rejects it there).
    func buildPayload(listenType: String, plays: [PlayEvent]) -> [String: Any] {
        let listens = plays.map { play -> [String: Any] in
            var trackMetadata: [String: Any] = [
                "artist_name": play.artist,
                "track_name": play.title,
            ]
            if let album = play.album { trackMetadata["release_name"] = album }
            var additional: [String: Any] = [:]
            additional["media_player"] = "Bòcan"
            additional["submission_client"] = "Bòcan"
            if let mbid = play.mbid { additional["recording_mbid"] = mbid }
            if play.duration > 0 { additional["duration_ms"] = Int(play.duration * 1000) }
            if !additional.isEmpty { trackMetadata["additional_info"] = additional }
            var listen: [String: Any] = ["track_metadata": trackMetadata]
            if listenType != "playing_now" {
                listen["listened_at"] = Int(play.playedAt.timeIntervalSince1970)
            }
            return listen
        }
        return ["listen_type": listenType, "payload": listens]
    }

    // MARK: HTTP

    /// POSTs `payload` to `path` under a `Token` bearer, mapping the HTTP status
    /// to a typed `ScrobbleError`. `providerID` tags any thrown error.
    @discardableResult
    func post(
        path: String,
        token: String,
        payload: [String: Any],
        providerID: String
    ) async throws -> [String: Any] {
        var components = URLComponents(url: self.endpoint, resolvingAgainstBaseURL: true)!
        components.path = path
        guard let url = components.url else {
            throw ScrobbleError.malformedResponse(provider: providerID, reason: "bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let (data, response) = try await self.http.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)

        if status >= 200, status < 300 {
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        switch status {
        case 401, 403:
            throw ScrobbleError.invalidCredentials(provider: providerID)
        case 429:
            throw ScrobbleError.transient(provider: providerID, reason: "rate limited", retryAfter: retryAfter ?? 60)
        case 500 ... 599:
            throw ScrobbleError.transient(provider: providerID, reason: "http \(status)", retryAfter: retryAfter)
        default:
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ScrobbleError.permanent(provider: providerID, reason: "http \(status): \(body.prefix(200))")
        }
    }
}
