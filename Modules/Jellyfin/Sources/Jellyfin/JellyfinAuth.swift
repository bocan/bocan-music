import Foundation
import Observability

// MARK: - JellyfinEndpoint

/// Where a server is, before it has a row in the database. The add flow builds
/// one from what the user typed.
public struct JellyfinEndpoint: Sendable, Equatable {
    public let serverURL: URL
    /// The client device id. Made once when the server row is created, and reused on every sign-in.
    public let deviceID: String
    public let allowSelfSignedTLS: Bool

    /// Checks the URL and strips trailing slashes.
    ///
    /// - Throws: `JellyfinError.invalidServerURL` if the scheme is not http or https, or there is no host.
    public init(serverURL: URL, deviceID: String, allowSelfSignedTLS: Bool = false) throws {
        guard let scheme = serverURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw JellyfinError.invalidServerURL("the address must start with http:// or https://")
        }
        guard let host = serverURL.host, !host.isEmpty else {
            throw JellyfinError.invalidServerURL("the address has no host name")
        }
        self.serverURL = JellyfinServer.normalise(serverURL)
        self.deviceID = deviceID
        self.allowSelfSignedTLS = allowSelfSignedTLS
    }
}

// MARK: - JellyfinAuthenticating

/// What the add-server flow needs from the sign-in layer. `JellyfinAuth` is the
/// one real implementation; the Settings tests pass a double so they need no network.
public protocol JellyfinAuthenticating: Sendable {
    func probe(_ endpoint: JellyfinEndpoint) async throws -> JellyfinServerInfo
    func quickConnectAvailable(_ endpoint: JellyfinEndpoint) async -> Bool
    func signIn(_ endpoint: JellyfinEndpoint, username: String, password: String) async throws -> JellyfinSession
    func quickConnect(
        _ endpoint: JellyfinEndpoint,
        policy: JellyfinQuickConnectPolicy
    ) -> AsyncThrowingStream<JellyfinQuickConnectEvent, Error>
}

// MARK: - JellyfinAuth

/// Everything that happens before a server has a token: probing it, signing in
/// with a password, and Quick Connect.
///
/// The password is passed straight to the server and is never stored or logged.
/// The result is a `JellyfinSession`, which `JellyfinServerStore` writes to the
/// Keychain.
public struct JellyfinAuth: JellyfinAuthenticating {
    typealias ClientFactory = @Sendable (JellyfinClientConfiguration) -> any JellyfinAuthClientProtocol
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let identity: JellyfinClientIdentity
    private let makeClient: ClientFactory
    private let sleep: Sleeper
    private let log = AppLogger.make(.jellyfin)

    public init() {
        self.init(
            identity: .current(),
            makeClient: { JellyfinSDKClient(configuration: $0) },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    init(identity: JellyfinClientIdentity, makeClient: @escaping ClientFactory, sleep: @escaping Sleeper) {
        self.identity = identity
        self.makeClient = makeClient
        self.sleep = sleep
    }

    private func client(for endpoint: JellyfinEndpoint) -> any JellyfinAuthClientProtocol {
        self.makeClient(JellyfinClientConfiguration(
            serverURL: endpoint.serverURL,
            deviceID: endpoint.deviceID,
            identity: self.identity,
            allowSelfSignedTLS: endpoint.allowSelfSignedTLS,
            userID: nil,
            accessToken: nil
        ))
    }

    // MARK: - Probe

    /// Asks the server for its name and version. This is "Test server": it needs no sign-in.
    public func probe(_ endpoint: JellyfinEndpoint) async throws -> JellyfinServerInfo {
        try await self.client(for: endpoint).serverInfo()
    }

    /// Whether Quick Connect is switched on. A server that does not answer counts as off.
    public func quickConnectAvailable(_ endpoint: JellyfinEndpoint) async -> Bool {
        do {
            return try await self.client(for: endpoint).quickConnectEnabled()
        } catch {
            self.log.info("jellyfin.auth.quickconnect.unavailable", ["error": String(reflecting: error)])
            return false
        }
    }

    // MARK: - Password

    /// Signs in with a user name and password.
    ///
    /// - Throws: `.unauthorized` for a wrong user name or password.
    public func signIn(_ endpoint: JellyfinEndpoint, username: String, password: String) async throws -> JellyfinSession {
        let session = try await self.client(for: endpoint).signIn(username: username, password: password)
        self.log.info("jellyfin.auth.signin.ok", ["method": "password"])
        return session
    }

    // MARK: - Quick Connect

    /// Starts Quick Connect.
    ///
    /// The stream yields `.waiting(code:)` with the code to approve in another
    /// signed-in session, then `.approved(_:)` and finishes. It throws
    /// `.quickConnectDisabled` when the server has it off, and
    /// `.quickConnectTimedOut` when nobody approves the code in time. Cancelling
    /// the task that reads the stream, or dropping the stream, stops polling.
    public func quickConnect(
        _ endpoint: JellyfinEndpoint,
        policy: JellyfinQuickConnectPolicy = JellyfinQuickConnectPolicy()
    ) -> AsyncThrowingStream<JellyfinQuickConnectEvent, Error> {
        let client = self.client(for: endpoint)
        let sleep = self.sleep
        let log = self.log
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard try await client.quickConnectEnabled() else {
                        throw JellyfinError.quickConnectDisabled
                    }
                    let ticket = try await client.quickConnectInitiate()
                    continuation.yield(.waiting(code: ticket.code))
                    let session = try await Self.poll(client: client, ticket: ticket, policy: policy, sleep: sleep)
                    log.info("jellyfin.auth.signin.ok", ["method": "quickConnect"])
                    continuation.yield(.approved(session))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Waits for the ticket to be approved, then signs in with it.
    private static func poll(
        client: any JellyfinAuthClientProtocol,
        ticket: JellyfinQuickConnectTicket,
        policy: JellyfinQuickConnectPolicy,
        sleep: Sleeper
    ) async throws -> JellyfinSession {
        var failures = 0
        for _ in 0 ..< policy.maxPolls {
            try await sleep(policy.interval)
            try Task.checkCancellation()
            do {
                if try await client.quickConnectIsApproved(ticket) {
                    return try await client.signIn(approved: ticket)
                }
                failures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                if failures > policy.failureTolerance {
                    throw error
                }
            }
        }
        throw JellyfinError.quickConnectTimedOut
    }
}
