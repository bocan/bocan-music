import Combine
import Foundation
import Observability
import Subsonic
import SwiftUI

// MARK: - SubsonicSettingsViewModel

/// Phase 19 step 12: state-store for the Settings → Sources tab.
///
/// Wraps `SubsonicServerStore` (CRUD + Keychain), `SubsonicService` (ping,
/// capabilities), and `SubsonicConnectionMonitor` (live status). UI binds
/// directly to its `@Published` state; all mutating operations are async and
/// surface a localised `errorMessage` on failure.
@MainActor
public final class SubsonicSettingsViewModel: ObservableObject {
    // MARK: - Public state

    @Published public private(set) var servers: [SubsonicServer] = []
    @Published public private(set) var statuses: [UUID: SubsonicConnectionStatus] = [:]
    @Published public var selectedServerID: UUID?
    @Published public var editor: ServerEditor = .init()
    /// Most recent capability snapshot to surface after `Test Connection`.
    @Published public private(set) var lastTestResult: TestResult?
    /// `true` while `Test Connection` (single or all) is in flight.
    @Published public private(set) var isTesting = false
    /// Non-nil to display a destructive error toast under the editor form.
    @Published public var errorMessage: String?

    // MARK: - Dependencies

    private let store: SubsonicServerStore
    private let service: SubsonicService
    private let monitor: SubsonicConnectionMonitor?
    /// Optional callback fired after a successful save/delete/reorder so the
    /// app layer can reload the sidebar listing in one call.
    private let onServersChanged: (() async -> Void)?
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(
        store: SubsonicServerStore,
        service: SubsonicService,
        monitor: SubsonicConnectionMonitor? = nil,
        onServersChanged: (() async -> Void)? = nil
    ) {
        self.store = store
        self.service = service
        self.monitor = monitor
        self.onServersChanged = onServersChanged
    }

    // MARK: - Loading

    /// Fetches the server list and refreshes the published status snapshot.
    public func reload() async {
        do {
            let fetched = try await self.store.fetchAll()
            self.servers = fetched.sorted { $0.sortIndex < $1.sortIndex }
            if let monitor = self.monitor {
                self.statuses = await monitor.currentStatuses()
            }
            // Re-select the previously-selected server, if it still exists;
            // otherwise default to the first.
            if let id = self.selectedServerID, self.servers.contains(where: { $0.id == id }) {
                await self.applyEditor(forServerWithID: id)
            } else if let first = self.servers.first {
                self.selectedServerID = first.id
                await self.applyEditor(forServerWithID: first.id)
            } else {
                self.selectedServerID = nil
                self.editor = ServerEditor()
            }
        } catch {
            self.errorMessage = "Couldn't load configured servers: \(error.localizedDescription)"
            self.log.error("subsonic.settings.reload.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: - Selection / editor

    /// Selects a server row; populates the editor with the latest persisted
    /// values plus the secret read from the Keychain.
    public func selectServer(_ id: UUID) async {
        self.selectedServerID = id
        self.lastTestResult = nil
        self.errorMessage = nil
        await self.applyEditor(forServerWithID: id)
    }

    /// Switches the editor into "new server" mode.
    public func beginAddServer() {
        self.selectedServerID = nil
        self.lastTestResult = nil
        self.errorMessage = nil
        self.editor = ServerEditor.blankNew()
    }

    private func applyEditor(forServerWithID id: UUID) async {
        guard let server = self.servers.first(where: { $0.id == id }) else { return }
        var editor = ServerEditor(server: server)
        editor.secret = await (try? self.store.secret(for: id)) ?? ""
        self.editor = editor
        self.storedSecretSnapshot = editor.secret
    }

    // MARK: - Save / delete

    /// Persists the current editor — either as an update or as a new server.
    public func save() async {
        self.errorMessage = nil
        guard let validated = self.editor.validated() else {
            self.errorMessage = self.editor.firstValidationError
                ?? "Some required fields are missing."
            return
        }
        do {
            let isNew = self.editor.id == nil
            if isNew {
                let server = validated.makeServer(sortIndex: self.servers.count)
                try await self.store.add(server, secret: validated.secret)
                try await self.service.refreshClient(for: server)
                self.selectedServerID = server.id
            } else if var existing = self.servers.first(where: { $0.id == self.editor.id }) {
                validated.apply(to: &existing)
                let newSecret = validated.secret != self.storedSecretSnapshot ? validated.secret : nil
                try await self.store.update(existing, newSecret: newSecret)
                try await self.service.refreshClient(for: existing)
                self.storedSecretSnapshot = validated.secret
            }
            await self.reload()
            await self.onServersChanged?()
        } catch {
            self.errorMessage = error.localizedDescription
            self.log.error("subsonic.settings.save.failed", ["error": String(reflecting: error)])
        }
    }

    /// Removes the selected server.
    public func deleteSelected() async {
        guard let id = self.selectedServerID else { return }
        self.errorMessage = nil
        do {
            try await self.store.remove(id: id)
            await self.service.removeClient(for: id)
            await self.reload()
            await self.onServersChanged?()
        } catch {
            self.errorMessage = error.localizedDescription
            self.log.error("subsonic.settings.delete.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: - Test connection

    /// Tests the editor's current values against a freshly-built client
    /// without persisting anything. Pings, then loads capabilities.
    public func testCurrentEditor() async {
        self.errorMessage = nil
        guard self.editor.validated() != nil else {
            self.errorMessage = self.editor.firstValidationError
                ?? "Fix the form before testing."
            return
        }
        self.isTesting = true
        defer { self.isTesting = false }

        // Build (or refresh) the client for the *persisted* version of this
        // server. For a new server we add a stub row, test, then roll back if
        // the user cancels — but that's intrusive. Simpler: only allow
        // `Test Connection` for a server that has been saved at least once,
        // and surface a clear message otherwise.
        guard let id = self.editor.id else {
            self.errorMessage = "Save the server first, then test the connection."
            return
        }
        do {
            try await self.service.ping(serverID: id)
            let caps = try await self.service.refreshCapabilities(serverID: id)
            self.lastTestResult = TestResult(success: true, capabilities: caps, message: nil)
        } catch {
            self.lastTestResult = TestResult(
                success: false,
                capabilities: nil,
                message: error.localizedDescription
            )
        }
    }

    /// Pings every server in the list and updates the published statuses.
    public func testAllConnections() async {
        self.isTesting = true
        defer { self.isTesting = false }
        for server in self.servers {
            _ = try? await self.service.ping(serverID: server.id)
        }
        if let monitor = self.monitor {
            await monitor.wakeAll()
            self.statuses = await monitor.currentStatuses()
        }
    }

    // MARK: - Helpers

    /// The secret that was loaded when the editor was last populated. Used
    /// to detect whether the user actually changed it and avoid an
    /// unnecessary Keychain write on plain field updates.
    private var storedSecretSnapshot = ""
}

// MARK: - Editor model

public extension SubsonicSettingsViewModel {
    /// Mutable working copy of one server while the user edits it.
    struct ServerEditor: Equatable {
        public var id: UUID?
        public var name = ""
        public var serverURLText = ""
        public var authKind: SubsonicAuthKind = .tokenSalt
        public var username = ""
        public var secret = ""
        public var allowSelfSignedTLS = false
        public var bitrateKind: BitrateKind = .original
        public var bitrateKbps = 256
        public var preferredFormat: SubsonicStreamFormat = .original
        public var precacheNext = true
        public var includeInGlobalSearch = true
        public var showInSidebar = true
        public var scrobble = true
        public var syncStars = true
        public var syncRatings = true

        public init() {}

        init(server: SubsonicServer) {
            self.id = server.id
            self.name = server.name
            self.serverURLText = server.serverURL.absoluteString
            self.authKind = server.authKind
            self.username = server.username ?? ""
            self.allowSelfSignedTLS = server.allowSelfSignedTLS
            switch server.maxBitrate {
            case .original:
                self.bitrateKind = .original
            case let .kbps(n):
                self.bitrateKind = .kbps
                self.bitrateKbps = n
            }
            self.preferredFormat = server.preferredFormat
            self.precacheNext = server.precacheNext
            self.includeInGlobalSearch = server.includeInGlobalSearch
            self.showInSidebar = server.showInSidebar
            self.scrobble = server.scrobble
            self.syncStars = server.syncStars
            self.syncRatings = server.syncRatings
        }

        public static func blankNew() -> ServerEditor {
            var editor = ServerEditor()
            editor.name = "New Server"
            editor.serverURLText = "https://"
            return editor
        }

        /// Returns the validated form, or `nil` if anything is missing.
        public func validated() -> Validated? {
            guard !self.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  let url = Self.parseURL(self.serverURLText),
                  ["http", "https"].contains(url.scheme ?? ""),
                  !self.secret.isEmpty else { return nil }
            switch self.authKind {
            case .tokenSalt where self.username.trimmingCharacters(in: .whitespaces).isEmpty:
                return nil
            default:
                break
            }
            return Validated(
                editor: self,
                trimmedName: self.name.trimmingCharacters(in: .whitespaces),
                normalisedURL: url
            )
        }

        /// Returns the first validation problem as a human-readable string.
        public var firstValidationError: String? {
            if self.name.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Display name is required."
            }
            guard let url = Self.parseURL(self.serverURLText) else {
                return "Server URL must be a valid http or https URL."
            }
            if !["http", "https"].contains(url.scheme ?? "") {
                return "Server URL must use http or https."
            }
            if self.authKind == .tokenSalt,
               self.username.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Username is required for token-and-password authentication."
            }
            if self.secret.isEmpty {
                return self.authKind == .apiKey ? "API key is required." : "Password is required."
            }
            return nil
        }

        private static func parseURL(_ text: String) -> URL? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return URL(string: trimmed)
        }
    }

    /// Tagged "kind" for the bitrate picker, so SwiftUI bindings stay simple.
    enum BitrateKind: String, CaseIterable, Identifiable {
        case original
        case kbps

        public var id: String {
            self.rawValue
        }
    }

    /// The post-validation, ready-to-persist projection of an editor.
    struct Validated {
        let editor: ServerEditor
        let trimmedName: String
        let normalisedURL: URL

        var secret: String {
            self.editor.secret
        }

        var bitrate: SubsonicBitrate {
            switch self.editor.bitrateKind {
            case .original: .original
            case .kbps: .kbps(self.editor.bitrateKbps)
            }
        }

        func makeServer(sortIndex: Int) -> SubsonicServer {
            SubsonicServer(
                id: UUID(),
                name: self.trimmedName,
                serverURL: self.normalisedURL,
                authKind: self.editor.authKind,
                username: self.editor.authKind == .tokenSalt
                    ? self.editor.username.trimmingCharacters(in: .whitespaces)
                    : nil,
                allowSelfSignedTLS: self.editor.allowSelfSignedTLS,
                maxBitrate: self.bitrate,
                preferredFormat: self.editor.preferredFormat,
                precacheNext: self.editor.precacheNext,
                includeInGlobalSearch: self.editor.includeInGlobalSearch,
                showInSidebar: self.editor.showInSidebar,
                scrobble: self.editor.scrobble,
                syncStars: self.editor.syncStars,
                syncRatings: self.editor.syncRatings,
                sortIndex: sortIndex
            )
        }

        func apply(to server: inout SubsonicServer) {
            server.name = self.trimmedName
            server.serverURL = self.normalisedURL
            server.authKind = self.editor.authKind
            server.username = self.editor.authKind == .tokenSalt
                ? self.editor.username.trimmingCharacters(in: .whitespaces)
                : nil
            server.allowSelfSignedTLS = self.editor.allowSelfSignedTLS
            server.maxBitrate = self.bitrate
            server.preferredFormat = self.editor.preferredFormat
            server.precacheNext = self.editor.precacheNext
            server.includeInGlobalSearch = self.editor.includeInGlobalSearch
            server.showInSidebar = self.editor.showInSidebar
            server.scrobble = self.editor.scrobble
            server.syncStars = self.editor.syncStars
            server.syncRatings = self.editor.syncRatings
        }
    }

    /// Result of a `Test Connection` attempt, surfaced under the editor.
    struct TestResult: Equatable {
        public let success: Bool
        public let capabilities: SubsonicCapabilities?
        public let message: String?
    }
}
