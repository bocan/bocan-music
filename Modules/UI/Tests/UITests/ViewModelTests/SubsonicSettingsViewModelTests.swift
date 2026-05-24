import Foundation
import Subsonic
import Testing
@testable import UI

@Suite("SubsonicSettingsViewModel.ServerEditor")
struct SubsonicSettingsViewModelEditorTests {
    typealias Editor = SubsonicSettingsViewModel.ServerEditor

    @Test("Blank editor fails validation with display-name error first.")
    func blankFailsOnName() {
        let editor = Editor()
        #expect(editor.validated() == nil)
        #expect(editor.firstValidationError?.contains("name") == true)
    }

    @Test("Non-http(s) URL is rejected.")
    func rejectsBadScheme() {
        var editor = Editor()
        editor.name = "Home"
        editor.serverURLText = "ftp://example.com"
        editor.username = "alice"
        editor.secret = "hunter2"
        #expect(editor.validated() == nil)
        #expect(editor.firstValidationError?.contains("http") == true)
    }

    @Test("Token-mode requires username.")
    func tokenModeRequiresUsername() {
        var editor = Editor()
        editor.name = "Home"
        editor.serverURLText = "https://music.example.com"
        editor.username = "   "
        editor.secret = "hunter2"
        editor.authKind = .tokenSalt
        #expect(editor.validated() == nil)
        #expect(editor.firstValidationError?.contains("Username") == true)
    }

    @Test("API-key mode does not require username.")
    func apiKeyModeIgnoresUsername() {
        var editor = Editor()
        editor.name = "Cloud"
        editor.serverURLText = "https://music.example.com"
        editor.username = ""
        editor.secret = "ak_live_abc"
        editor.authKind = .apiKey
        let validated = editor.validated()
        #expect(validated != nil)
        let server = validated?.makeServer(sortIndex: 0)
        #expect(server?.authKind == .apiKey)
        #expect(server?.username == nil)
    }

    @Test("Empty secret fails with format-aware message.")
    func secretRequired() {
        var editor = Editor()
        editor.name = "Home"
        editor.serverURLText = "https://music.example.com"
        editor.authKind = .apiKey
        editor.secret = ""
        #expect(editor.validated() == nil)
        #expect(editor.firstValidationError?.contains("API key") == true)
    }

    @Test("Validated → makeServer round-trips all fields.")
    func makeServerRoundTrip() throws {
        var editor = Editor()
        editor.name = "  Library  "
        editor.serverURLText = "https://music.example.com/"
        editor.authKind = .tokenSalt
        editor.username = "alice"
        editor.secret = "hunter2"
        editor.allowSelfSignedTLS = true
        editor.bitrateKind = .kbps
        editor.bitrateKbps = 256
        editor.preferredFormat = .opus
        editor.precacheNext = false
        editor.includeInGlobalSearch = false
        editor.showInSidebar = false
        editor.scrobble = false
        editor.syncStars = false
        editor.syncRatings = false

        let validated = try #require(editor.validated())
        let server = validated.makeServer(sortIndex: 3)

        #expect(server.name == "Library")
        #expect(server.serverURL.absoluteString == "https://music.example.com")
        #expect(server.authKind == .tokenSalt)
        #expect(server.username == "alice")
        #expect(server.allowSelfSignedTLS)
        if case let .kbps(n) = server.maxBitrate {
            #expect(n == 256)
        } else {
            Issue.record("Expected .kbps(256)")
        }
        #expect(server.preferredFormat == .opus)
        #expect(server.precacheNext == false)
        #expect(server.includeInGlobalSearch == false)
        #expect(server.showInSidebar == false)
        #expect(server.scrobble == false)
        #expect(server.syncStars == false)
        #expect(server.syncRatings == false)
        #expect(server.sortIndex == 3)
    }

    @Test("Editor built from SubsonicServer mirrors every field.")
    func roundTripFromServer() throws {
        let server = try SubsonicServer(
            name: "Cloud",
            serverURL: #require(URL(string: "https://music.example.com")),
            authKind: .apiKey,
            allowSelfSignedTLS: true,
            maxBitrate: .kbps(192),
            preferredFormat: .flac,
            precacheNext: false,
            includeInGlobalSearch: false,
            showInSidebar: false,
            scrobble: false,
            syncStars: false,
            syncRatings: false,
            sortIndex: 7
        )
        let editor = Editor(server: server)
        #expect(editor.name == "Cloud")
        #expect(editor.serverURLText == "https://music.example.com")
        #expect(editor.authKind == .apiKey)
        #expect(editor.allowSelfSignedTLS)
        #expect(editor.bitrateKind == .kbps)
        #expect(editor.bitrateKbps == 192)
        #expect(editor.preferredFormat == .flac)
        #expect(editor.precacheNext == false)
        #expect(editor.includeInGlobalSearch == false)
        #expect(editor.showInSidebar == false)
        #expect(editor.scrobble == false)
        #expect(editor.syncStars == false)
        #expect(editor.syncRatings == false)
    }

    @Test("Validated.apply mutates existing server in place.")
    func applyMutates() throws {
        var server = try SubsonicServer(
            name: "Old",
            serverURL: #require(URL(string: "https://old.example.com")),
            authKind: .tokenSalt,
            username: "old",
            sortIndex: 5
        )

        var editor = Editor()
        editor.name = "New"
        editor.serverURLText = "https://new.example.com"
        editor.authKind = .apiKey
        editor.username = ""
        editor.secret = "ak_new"
        editor.bitrateKind = .original
        editor.preferredFormat = .mp3

        let validated = try #require(editor.validated())
        validated.apply(to: &server)

        #expect(server.name == "New")
        #expect(server.serverURL.absoluteString == "https://new.example.com")
        #expect(server.authKind == .apiKey)
        #expect(server.username == nil)
        #expect(server.preferredFormat == .mp3)
        if case .original = server.maxBitrate {
            // ok
        } else {
            Issue.record("Expected .original")
        }
        // sortIndex must be preserved on apply (not part of editor).
        #expect(server.sortIndex == 5)
    }
}
