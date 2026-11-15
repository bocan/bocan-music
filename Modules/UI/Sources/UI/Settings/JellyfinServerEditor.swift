import Foundation
import Jellyfin

// MARK: - Editor model

/// The working copy of one Jellyfin server while the user edits it.
public extension JellyfinSettingsViewModel {
    struct ServerEditor: Equatable {
        /// `nil` while the server is not saved yet.
        public var id: UUID?
        /// The device id for a server that is not saved yet. It is made once per draft, so
        /// a failed sign-in and a second try show one device on the server, not two. A saved
        /// server keeps the id in its row, and the editor never changes that.
        public var deviceID = UUID().uuidString
        public var name = ""
        public var serverURLText = ""
        /// What the user types to sign in. It is empty for a saved server.
        public var username = ""
        /// Typed, sent once, then cleared. It is never stored.
        public var password = ""
        /// The account a saved server is signed in as. Display only.
        public var signedInAs: String?
        public var allowSelfSignedTLS = false
        public var bitrateKind: BitrateKind = .original
        public var bitrateKbps = 256
        public var preferredFormat: JellyfinStreamFormat = .original
        public var precacheNext = true
        public var includeInGlobalSearch = true
        public var showInSidebar = true
        public var scrobble = true
        public var syncStars = true

        public init() {}

        init(server: JellyfinServer) {
            self.id = server.id
            self.deviceID = server.deviceID
            self.name = server.name
            self.serverURLText = server.serverURL.absoluteString
            self.signedInAs = server.username
            self.allowSelfSignedTLS = server.allowSelfSignedTLS
            switch server.maxBitrate {
            case .original:
                self.bitrateKind = .original

            case let .kbps(value):
                self.bitrateKind = .kbps
                self.bitrateKbps = value
            }
            self.preferredFormat = server.preferredFormat
            self.precacheNext = server.precacheNext
            self.includeInGlobalSearch = server.includeInGlobalSearch
            self.showInSidebar = server.showInSidebar
            self.scrobble = server.scrobble
            self.syncStars = server.syncStars
        }

        public static func blankNew() -> Self {
            var editor = Self()
            // The name stays empty: the server's own name fills it after sign-in.
            editor.serverURLText = ""
            return editor
        }

        /// The bitrate cap works only when a format is chosen. With Original the
        /// server sends the file as it is, so the control is greyed out.
        public var isBitrateEnabled: Bool {
            self.preferredFormat != .original
        }

        // MARK: Address

        private var trimmedURLText: String {
            self.serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The address as a checked endpoint.
        ///
        /// - Throws: `JellyfinError.invalidServerURL` for an empty address, a wrong
        ///   scheme or a missing host.
        public func endpoint() throws -> JellyfinEndpoint {
            guard !self.trimmedURLText.isEmpty, let url = URL(string: self.trimmedURLText) else {
                throw JellyfinError.invalidServerURL("the address is not valid")
            }
            return try JellyfinEndpoint(
                serverURL: url,
                deviceID: self.deviceID,
                allowSelfSignedTLS: self.allowSelfSignedTLS
            )
        }

        /// The first problem with the address, as plain text, or `nil`.
        public var addressProblem: String? {
            do {
                _ = try self.endpoint()
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        // MARK: Validation

        /// Why "Sign In" cannot run yet, or `nil`.
        public func signInProblem() -> String? {
            if let problem = self.addressProblem {
                return problem
            }
            if self.username.trimmingCharacters(in: .whitespaces).isEmpty {
                return L10n.string("User name is required.")
            }
            if self.password.isEmpty {
                return L10n.string("Password is required.")
            }
            return nil
        }

        /// Why "Save" cannot run yet, or `nil`.
        public func saveProblem() -> String? {
            if self.name.trimmingCharacters(in: .whitespaces).isEmpty {
                return L10n.string("Display name is required.")
            }
            return self.addressProblem
        }

        // MARK: Building a server

        /// A new server from a finished sign-in. A blank display name takes the
        /// server's own name, then its host name.
        func makeServer(session: JellyfinSession, fallbackName: String?, sortIndex: Int) -> JellyfinServer {
            let typed = self.name.trimmingCharacters(in: .whitespaces)
            let name = typed.isEmpty ? (fallbackName ?? "Jellyfin") : typed
            let url = URL(string: self.trimmedURLText) ?? URL(filePath: "/")
            return JellyfinServer(
                name: name,
                serverURL: url,
                userID: session.userID,
                username: session.username,
                deviceID: self.deviceID,
                allowSelfSignedTLS: self.allowSelfSignedTLS,
                maxBitrate: self.bitrate,
                preferredFormat: self.preferredFormat,
                precacheNext: self.precacheNext,
                includeInGlobalSearch: self.includeInGlobalSearch,
                showInSidebar: self.showInSidebar,
                scrobble: self.scrobble,
                syncStars: self.syncStars,
                sortIndex: sortIndex
            )
        }

        /// Copies the edited fields onto a saved server. It never touches the id,
        /// the device id, the user or the token.
        func apply(to server: inout JellyfinServer) throws {
            guard let url = URL(string: self.trimmedURLText) else {
                throw JellyfinError.invalidServerURL("the address is not valid")
            }
            server.name = self.name.trimmingCharacters(in: .whitespaces)
            server.serverURL = url
            server.allowSelfSignedTLS = self.allowSelfSignedTLS
            server.maxBitrate = self.bitrate
            server.preferredFormat = self.preferredFormat
            server.precacheNext = self.precacheNext
            server.includeInGlobalSearch = self.includeInGlobalSearch
            server.showInSidebar = self.showInSidebar
            server.scrobble = self.scrobble
            server.syncStars = self.syncStars
        }

        var bitrate: JellyfinBitrate {
            switch self.bitrateKind {
            case .original:
                .original

            case .kbps:
                .kbps(self.bitrateKbps)
            }
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
}
