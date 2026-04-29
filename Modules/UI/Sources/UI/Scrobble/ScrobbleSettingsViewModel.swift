import Foundation
import Observability
import Scrobble
import SwiftUI

// MARK: - ScrobbleSettingsViewModel

/// Drives `ScrobbleSettingsView` and `ConnectSheet`. Holds connection state
/// for both providers, surfaces queue stats, and brokers connect/disconnect
/// flows. The actual scrobbling pipeline lives in `ScrobbleService`; this view
/// model is a thin façade so SwiftUI can stay declarative.
@MainActor
public final class ScrobbleSettingsViewModel: ObservableObject {
    public struct ProviderStatus: Sendable, Equatable {
        public let id: String
        public let displayName: String
        public var isConnected: Bool
        public var username: String?
    }

    @Published public private(set) var lastFm: ProviderStatus
    @Published public private(set) var listenBrainz: ProviderStatus
    @Published public private(set) var stats: ScrobbleQueueRepository.Stats?
    @Published public var isAuthenticatingLastFm = false
    @Published public var lastFmAuthError: String?
    @Published public var listenBrainzTokenError: String?

    private let service: ScrobbleService
    private let credentials: CredentialsAdapter
    private let openURL: @Sendable (URL) -> Void
    private let log = AppLogger.make(.scrobble)
    private var statsTask: Task<Void, Never>?

    public init(
        service: ScrobbleService,
        credentials: CredentialsAdapter,
        openURL: @escaping @Sendable (URL) -> Void
    ) {
        self.service = service
        self.credentials = credentials
        self.openURL = openURL
        self.lastFm = .init(id: "lastfm", displayName: "Last.fm", isConnected: false, username: nil)
        self.listenBrainz = .init(id: "listenbrainz", displayName: "ListenBrainz", isConnected: false, username: nil)
    }

    public func appear() {
        Task { await self.refreshConnectionState() }
        self.statsTask?.cancel()
        let repo = self.service.queueRepository
        self.statsTask = Task { [weak self] in
            do {
                for try await stats in repo.observeStats() {
                    await MainActor.run { self?.stats = stats }
                }
            } catch {
                AppLogger.make(.scrobble).warning("scrobble.stats.stream.failed", ["error": String(reflecting: error)])
            }
        }
    }

    public func disappear() {
        self.statsTask?.cancel()
        self.statsTask = nil
    }

    // MARK: Connection state

    public func refreshConnectionState() async {
        let lastFmKey: String? = await self.tryFetch { try await self.credentials.lastFmSessionKey() }
        let lastFmUser: String? = await self.tryFetch { try await self.credentials.lastFmUsername() }
        let listenToken: String? = await self.tryFetch { try await self.credentials.listenBrainzToken() }
        let listenUser: String? = await self.tryFetch { try await self.credentials.listenBrainzUsername() }
        self.lastFm = .init(
            id: "lastfm",
            displayName: "Last.fm",
            isConnected: !(lastFmKey?.isEmpty ?? true),
            username: lastFmUser
        )
        self.listenBrainz = .init(
            id: "listenbrainz",
            displayName: "ListenBrainz",
            isConnected: !(listenToken?.isEmpty ?? true),
            username: listenUser
        )
    }

    private func tryFetch(_ body: @Sendable () async throws -> String?) async -> String? {
        do { return try await body() } catch { return nil }
    }

    // MARK: Last.fm flow

    public func connectLastFm() async {
        self.isAuthenticatingLastFm = true
        self.lastFmAuthError = nil
        defer { self.isAuthenticatingLastFm = false }

        guard let provider = await self.service.provider(id: "lastfm") as? LastFmProvider else {
            self.lastFmAuthError = "Last.fm is not configured. Set BocanLastFmApiKey in Info.plist."
            return
        }
        let auth = LastFmAuth(
            provider: provider,
            credentials: self.credentials,
            openURL: self.openURL
        )
        do {
            _ = try await auth.connect()
            await self.refreshConnectionState()
        } catch {
            self.log.error("scrobble.lastfm.connect.failed", ["error": String(reflecting: error)])
            self.lastFmAuthError = self.message(for: error)
        }
    }

    public func disconnectLastFm() async {
        try? await self.credentials.clearLastFmSession()
        await self.refreshConnectionState()
    }

    // MARK: ListenBrainz flow

    public func connectListenBrainz(token: String) async {
        self.listenBrainzTokenError = nil
        guard let provider = await self.service.provider(id: "listenbrainz") as? ListenBrainzProvider else {
            self.listenBrainzTokenError = "ListenBrainz is unavailable."
            return
        }
        do {
            let user = try await provider.validate(token: token)
            try await self.credentials.setListenBrainz(token: token, username: user)
            await self.refreshConnectionState()
        } catch {
            self.log.error("scrobble.listenbrainz.connect.failed", ["error": String(reflecting: error)])
            self.listenBrainzTokenError = self.message(for: error)
        }
    }

    public func disconnectListenBrainz() async {
        try? await self.credentials.clearListenBrainz()
        await self.refreshConnectionState()
    }

    // MARK: Queue actions

    public func resubmitDeadLetters() async {
        let repo = self.service.queueRepository
        do {
            try await repo.reviveDead()
            await self.service.kickAll()
        } catch {
            self.log.warning("scrobble.dead.revive.failed", ["error": String(reflecting: error)])
        }
    }

    public func purgeDeadLetters() async {
        let repo = self.service.queueRepository
        try? await repo.purgeDead()
    }

    private func message(for error: Error) -> String {
        if let scrobbleError = error as? ScrobbleError {
            return String(describing: scrobbleError)
        }
        return error.localizedDescription
    }
}
