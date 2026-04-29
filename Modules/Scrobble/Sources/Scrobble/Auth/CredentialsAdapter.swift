import Foundation

// MARK: - CredentialsAdapter

/// Adapts the generic `Credentials` actor into the narrow per-provider stores
/// that `LastFmProvider` and `ListenBrainzProvider` consume. Keeping the
/// per-provider stores narrow lets the providers be tested with simple
/// in-memory fixtures and keeps the keychain account names in one place.
public actor CredentialsAdapter: LastFmCredentialsStore, ListenBrainzCredentialsStore {
    public static let lastFmSessionKeyAccount = "lastfm.session"
    public static let lastFmUsernameAccount = "lastfm.username"
    public static let listenBrainzTokenAccount = "listenbrainz.token"
    public static let listenBrainzUsernameAccount = "listenbrainz.username"

    private let store: Credentials

    public init(store: Credentials) {
        self.store = store
    }

    // MARK: Last.fm

    public func lastFmSessionKey() async throws -> String? {
        try await self.store.string(for: Self.lastFmSessionKeyAccount)
    }

    public func setLastFmSession(key: String, username: String) async throws {
        try await self.store.set(key, for: Self.lastFmSessionKeyAccount)
        try await self.store.set(username, for: Self.lastFmUsernameAccount)
    }

    public func clearLastFmSession() async throws {
        try await self.store.remove(account: Self.lastFmSessionKeyAccount)
        try await self.store.remove(account: Self.lastFmUsernameAccount)
    }

    public func lastFmUsername() async throws -> String? {
        try await self.store.string(for: Self.lastFmUsernameAccount)
    }

    // MARK: ListenBrainz

    public func listenBrainzToken() async throws -> String? {
        try await self.store.string(for: Self.listenBrainzTokenAccount)
    }

    public func setListenBrainz(token: String, username: String) async throws {
        try await self.store.set(token, for: Self.listenBrainzTokenAccount)
        try await self.store.set(username, for: Self.listenBrainzUsernameAccount)
    }

    public func clearListenBrainz() async throws {
        try await self.store.remove(account: Self.listenBrainzTokenAccount)
        try await self.store.remove(account: Self.listenBrainzUsernameAccount)
    }

    public func listenBrainzUsername() async throws -> String? {
        try await self.store.string(for: Self.listenBrainzUsernameAccount)
    }
}
