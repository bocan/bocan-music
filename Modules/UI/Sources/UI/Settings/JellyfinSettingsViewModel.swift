import Combine
import Foundation
import Jellyfin
import Observability
import SwiftUI

// MARK: - JellyfinSettingsViewModel

/// ADR-097, slice 3: state for Settings, Sources, Jellyfin.
///
/// It wraps `JellyfinServerStore` (rows and the Keychain token), `JellyfinService`
/// (client pool, ping, removal), `JellyfinConnectionMonitor` (live status) and a
/// `JellyfinAuthenticating` (probe, password sign-in, Quick Connect).
///
/// **The password is never kept.** It lives in `editor.password` only while the
/// user types it, is sent to the server once and is cleared before the answer
/// comes back. Only the access token is stored, in the Keychain, by the store.
@MainActor
public final class JellyfinSettingsViewModel: ObservableObject {
    // MARK: - Public state

    @Published public private(set) var servers: [JellyfinServer] = []
    @Published public private(set) var statuses: [UUID: JellyfinConnectionStatus] = [:]
    @Published public var selectedServerID: UUID?
    @Published public var editor: ServerEditor = .init()
    /// `true` while the editor holds a server that is not saved yet.
    @Published public private(set) var isAddingNew = false
    /// The latest "Test server" answer.
    @Published public private(set) var lastTestResult: TestResult?
    /// `true` while "Test server" is running.
    @Published public private(set) var isTesting = false
    /// `true` while a password sign-in or a Quick Connect sign-in is running.
    @Published public private(set) var isSigningIn = false
    /// The Quick Connect code to approve in another signed-in session, while it waits.
    @Published public private(set) var quickConnectCode: String?
    /// Non-nil to show a red error line under the form.
    @Published public var errorMessage: String?

    // MARK: - Dependencies

    private let store: JellyfinServerStore
    private let service: JellyfinService
    private let auth: any JellyfinAuthenticating
    private let monitor: JellyfinConnectionMonitor?
    /// Called after a server is added, changed or removed, so the sidebar reloads.
    private let onServersChanged: (() async -> Void)?
    private let log = AppLogger.make(.ui)
    private let quickConnectPolicy: JellyfinQuickConnectPolicy
    private nonisolated(unsafe) var quickConnectTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        store: JellyfinServerStore,
        service: JellyfinService,
        auth: any JellyfinAuthenticating = JellyfinAuth(),
        monitor: JellyfinConnectionMonitor? = nil,
        quickConnectPolicy: JellyfinQuickConnectPolicy = JellyfinQuickConnectPolicy(),
        onServersChanged: (() async -> Void)? = nil
    ) {
        self.store = store
        self.service = service
        self.auth = auth
        self.monitor = monitor
        self.quickConnectPolicy = quickConnectPolicy
        self.onServersChanged = onServersChanged
    }

    deinit {
        self.quickConnectTask?.cancel()
    }

    // MARK: - Loading

    /// Fetches the server list and the live statuses, and keeps the editor in step.
    public func reload() async {
        do {
            self.servers = try await self.store.fetchAll().sorted { $0.sortIndex < $1.sortIndex }
        } catch {
            self.errorMessage = L10n.string("Couldn't load configured servers: \(error.localizedDescription)")
            self.log.error("ui.jellyfin.settings.reload.failed", ["error": String(reflecting: error)])
            return
        }
        if let monitor = self.monitor {
            self.statuses = await monitor.currentStatuses()
        }
        if self.isAddingNew {
            return
        }
        if let id = self.selectedServerID, self.servers.contains(where: { $0.id == id }) {
            self.applyEditor(forServerWithID: id)
        } else if let first = self.servers.first {
            self.selectedServerID = first.id
            self.applyEditor(forServerWithID: first.id)
        } else {
            self.selectedServerID = nil
            self.editor = ServerEditor()
        }
    }

    // MARK: - Selection

    /// Selects a saved server and fills the editor from its row.
    public func selectServer(_ id: UUID) {
        self.cancelQuickConnect()
        self.isAddingNew = false
        self.selectedServerID = id
        self.lastTestResult = nil
        self.errorMessage = nil
        self.applyEditor(forServerWithID: id)
    }

    /// Switches the editor to a new, unsaved server.
    public func beginAddServer() {
        self.cancelQuickConnect()
        self.isAddingNew = true
        self.selectedServerID = nil
        self.lastTestResult = nil
        self.errorMessage = nil
        self.editor = ServerEditor.blankNew()
    }

    private func applyEditor(forServerWithID id: UUID) {
        guard let server = self.servers.first(where: { $0.id == id }) else { return }
        self.editor = ServerEditor(server: server)
    }

    /// `true` when the selected server's token was refused, so the editor offers "Sign in again".
    public var needsSignIn: Bool {
        guard let id = self.editor.id else { return false }
        return self.statuses[id]?.requiresUserAction ?? false
    }

    // MARK: - Test server

    /// Asks the server for its name and version. It needs no sign-in, so it
    /// works before a server is saved. For a saved server it also makes one
    /// signed-in call, so a revoked token shows here.
    public func testServer() async {
        self.errorMessage = nil
        let endpoint: JellyfinEndpoint
        do {
            endpoint = try self.editor.endpoint()
        } catch {
            self.errorMessage = error.localizedDescription
            return
        }
        self.isTesting = true
        defer { self.isTesting = false }
        do {
            let info = try await self.auth.probe(endpoint)
            let quickConnect = await self.auth.quickConnectAvailable(endpoint)
            var signedIn: Bool?
            if let id = self.editor.id {
                do {
                    try await self.service.ping(serverID: id)
                    signedIn = true
                } catch {
                    signedIn = false
                }
            }
            self.lastTestResult = TestResult(
                success: true,
                serverName: info.serverName,
                version: info.version,
                quickConnectAvailable: quickConnect,
                signedIn: signedIn,
                message: nil
            )
        } catch {
            self.lastTestResult = TestResult(
                success: false,
                serverName: nil,
                version: nil,
                quickConnectAvailable: false,
                signedIn: nil,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Sign in

    /// Signs in with the editor's user name and password. The password is
    /// cleared before the request starts.
    public func signInWithPassword() async {
        self.errorMessage = nil
        if let problem = self.editor.signInProblem() {
            self.errorMessage = problem
            return
        }
        let endpoint: JellyfinEndpoint
        do {
            endpoint = try self.editor.endpoint()
        } catch {
            self.errorMessage = error.localizedDescription
            return
        }
        let username = self.editor.username.trimmingCharacters(in: .whitespaces)
        let password = self.editor.password
        self.editor.password = ""
        self.isSigningIn = true
        defer { self.isSigningIn = false }
        do {
            let session = try await self.auth.signIn(endpoint, username: username, password: password)
            await self.finishSignIn(session, endpoint: endpoint)
        } catch {
            self.errorMessage = error.localizedDescription
            self.log.warning("ui.jellyfin.settings.signIn.failed", ["error": String(reflecting: error)])
        }
    }

    /// Starts Quick Connect. `quickConnectCode` shows the code while the server waits.
    public func startQuickConnect() {
        self.errorMessage = nil
        let endpoint: JellyfinEndpoint
        do {
            endpoint = try self.editor.endpoint()
        } catch {
            self.errorMessage = error.localizedDescription
            return
        }
        self.cancelQuickConnect()
        self.isSigningIn = true
        let stream = self.auth.quickConnect(endpoint, policy: self.quickConnectPolicy)
        self.quickConnectTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case let .waiting(code):
                        self.quickConnectCode = code

                    case let .approved(session):
                        self.quickConnectCode = nil
                        await self.finishSignIn(session, endpoint: endpoint)
                    }
                }
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.log.warning("ui.jellyfin.settings.quickConnect.failed", ["error": String(reflecting: error)])
            }
            self?.quickConnectCode = nil
            self?.isSigningIn = false
        }
    }

    /// Stops polling and hides the code. Safe to call when nothing is running.
    public func cancelQuickConnect() {
        self.quickConnectTask?.cancel()
        self.quickConnectTask = nil
        self.quickConnectCode = nil
        self.isSigningIn = false
    }

    /// Stores the new session: adds the server, or replaces the token of a saved one.
    private func finishSignIn(_ session: JellyfinSession, endpoint: JellyfinEndpoint) async {
        do {
            if let id = self.editor.id, var existing = self.servers.first(where: { $0.id == id }) {
                existing.userID = session.userID
                existing.username = session.username
                try await self.store.update(existing, newSession: session)
                try await self.service.refreshClient(for: existing)
                // The monitor stops for good on a 401, so start it again.
                await self.monitor?.stopMonitoring(serverID: id)
                await self.monitor?.startMonitoring(serverID: id)
            } else {
                let fallback = await self.serverName(at: endpoint)
                let server = self.editor.makeServer(
                    session: session,
                    fallbackName: fallback ?? endpoint.serverURL.host,
                    sortIndex: self.servers.count
                )
                try await self.store.add(server, session: session)
                self.isAddingNew = false
                self.selectedServerID = server.id
                try await self.service.refreshClient(for: server)
                await self.monitor?.startMonitoring(serverID: server.id)
            }
            await self.reload()
            await self.onServersChanged?()
        } catch {
            self.errorMessage = error.localizedDescription
            self.log.error("ui.jellyfin.settings.finishSignIn.failed", ["error": String(reflecting: error)])
            await self.reload()
        }
    }

    /// The server's own name, used when the user left the display name blank.
    /// A server that does not answer simply gives no name.
    private func serverName(at endpoint: JellyfinEndpoint) async -> String? {
        do {
            return try await self.auth.probe(endpoint).serverName
        } catch {
            self.log.info("ui.jellyfin.settings.serverName.unavailable", ["error": String(reflecting: error)])
            return nil
        }
    }

    // MARK: - Save / delete

    /// Saves the changes to a saved server. A new server is saved by signing in.
    public func save() async {
        self.errorMessage = nil
        guard let id = self.editor.id, var existing = self.servers.first(where: { $0.id == id }) else { return }
        guard self.editor.saveProblem() == nil else {
            self.errorMessage = self.editor.saveProblem()
            return
        }
        do {
            try self.editor.apply(to: &existing)
            try await self.store.update(existing)
            try await self.service.refreshClient(for: existing)
            await self.reload()
            await self.onServersChanged?()
        } catch {
            self.errorMessage = error.localizedDescription
            self.log.error("ui.jellyfin.settings.save.failed", ["error": String(reflecting: error)])
        }
    }

    /// Removes the selected server. The server is asked to end the token first,
    /// but one that cannot be reached never blocks the removal.
    public func deleteSelected() async {
        guard let id = self.selectedServerID else { return }
        self.errorMessage = nil
        do {
            try await self.service.removeServer(id: id)
            await self.monitor?.stopMonitoring(serverID: id)
            self.selectedServerID = nil
            await self.reload()
            await self.onServersChanged?()
        } catch {
            self.errorMessage = error.localizedDescription
            self.log.error("ui.jellyfin.settings.delete.failed", ["error": String(reflecting: error)])
        }
    }

    /// Re-pings every server and refreshes the statuses.
    public func testAllConnections() async {
        self.isTesting = true
        defer { self.isTesting = false }
        await self.monitor?.wakeAll()
        if let monitor = self.monitor {
            self.statuses = await monitor.currentStatuses()
        }
    }
}

// MARK: - Test result

/// Types used by the Jellyfin settings view model.
public extension JellyfinSettingsViewModel {
    /// The answer of "Test server", shown under the form.
    struct TestResult: Equatable {
        public let success: Bool
        public let serverName: String?
        public let version: String?
        public let quickConnectAvailable: Bool
        /// For a saved server: whether a signed-in call worked. `nil` for an unsaved one.
        public let signedIn: Bool?
        public let message: String?
    }
}
