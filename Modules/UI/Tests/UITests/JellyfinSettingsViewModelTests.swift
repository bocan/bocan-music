import Foundation
import Jellyfin
import Persistence
import Security
import Testing
@testable import UI

// MARK: - Keychain probe

/// The add flow stores a token in the login Keychain. Some `swift test`
/// environments (headless CI) cannot reach it, so the flow tests are skipped there.
private func keychainAvailable() -> Bool {
    let base: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "io.cloudcauldron.bocan.jellyfin.ui-probe",
        kSecAttrAccount: "probe-\(UUID().uuidString)",
    ]
    var add = base
    add[kSecValueData] = Data("x".utf8)
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
    _ = SecItemDelete(base as CFDictionary)
    return true
}

// MARK: - Auth double

/// A sign-in layer that answers from a script and never touches the network.
private final class StubAuth: JellyfinAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(username: String, password: String)] = []
    var signInResult: Result<JellyfinSession, JellyfinError> = .success(
        JellyfinSession(userID: "user-1", username: "chris", accessToken: "TOKEN-FOR-TESTS")
    )
    var quickConnectEvents: [JellyfinQuickConnectEvent] = []
    var quickConnectError: JellyfinError?
    var quickConnectHangs = false
    var info = JellyfinServerInfo(serverName: "Basement", version: "12.2.0", serverID: "abc")

    var passwords: [(username: String, password: String)] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded
    }

    func probe(_ endpoint: JellyfinEndpoint) async throws -> JellyfinServerInfo {
        self.info
    }

    func quickConnectAvailable(_ endpoint: JellyfinEndpoint) async -> Bool {
        true
    }

    func signIn(_ endpoint: JellyfinEndpoint, username: String, password: String) async throws -> JellyfinSession {
        self.record(username: username, password: password)
        return try self.signInResult.get()
    }

    /// Synchronous, so the lock is never held across a suspension point.
    private func record(username: String, password: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.recorded.append((username, password))
    }

    func quickConnect(
        _ endpoint: JellyfinEndpoint,
        policy: JellyfinQuickConnectPolicy
    ) -> AsyncThrowingStream<JellyfinQuickConnectEvent, Error> {
        let events = self.quickConnectEvents
        let error = self.quickConnectError
        let hangs = self.quickConnectHangs
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let error {
                continuation.finish(throwing: error)
            } else if !hangs {
                continuation.finish()
            }
        }
    }
}

// MARK: - Harness

@MainActor
private struct Harness {
    let vm: JellyfinSettingsViewModel
    let store: JellyfinServerStore
    let auth: StubAuth
    let changed: Counter
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored
    }

    func bump() {
        self.lock.lock()
        self.stored += 1
        self.lock.unlock()
    }
}

@MainActor
private func makeHarness(auth: StubAuth = StubAuth()) async throws -> Harness {
    let database = try await Persistence.Database(location: .inMemory)
    let repository = JellyfinServerRepository(database: database)
    let store = JellyfinServerStore(
        repository: repository,
        keychainService: "io.cloudcauldron.bocan.jellyfin.ui-test.\(UUID().uuidString)"
    )
    let service = JellyfinService(store: store)
    let changed = Counter()
    let vm = JellyfinSettingsViewModel(store: store, service: service, auth: auth) { changed.bump() }
    return Harness(vm: vm, store: store, auth: auth, changed: changed)
}

// MARK: - Editor (no Keychain needed)

@Suite("JellyfinSettingsViewModel.ServerEditor")
struct JellyfinServerEditorTests {
    typealias Editor = JellyfinSettingsViewModel.ServerEditor

    private func filled() -> Editor {
        var editor = Editor()
        editor.serverURLText = "https://jf.example.test/"
        editor.username = "chris"
        editor.password = "hunter2"
        return editor
    }

    @Test("a blank editor has no name and no address, and the first sign-in problem is the address")
    func blank() {
        let editor = Editor.blankNew()
        #expect(editor.serverURLText.isEmpty)
        #expect(editor.name.isEmpty)
        #expect(editor.signInProblem() != nil)
        #expect(editor.saveProblem() != nil)
    }

    @Test("a non-http address is refused with a plain message")
    func badScheme() {
        var editor = self.filled()
        editor.serverURLText = "ftp://jf.example.test"
        #expect(editor.addressProblem?.contains("http") == true)
        editor.serverURLText = "https://"
        #expect(editor.addressProblem != nil)
    }

    @Test("sign-in needs a user name and a password, nothing else")
    func signInNeeds() {
        var editor = self.filled()
        #expect(editor.signInProblem() == nil, "the display name is optional: the server's own name fills it")
        editor.username = "  "
        #expect(editor.signInProblem()?.contains("User name") == true)
        editor.username = "chris"
        editor.password = ""
        #expect(editor.signInProblem()?.contains("Password") == true)
    }

    @Test("a saved server needs a display name")
    func saveNeedsName() {
        var editor = self.filled()
        #expect(editor.saveProblem()?.contains("name") == true)
        editor.name = "Home"
        #expect(editor.saveProblem() == nil)
    }

    @Test("the endpoint keeps the draft's device id and strips the trailing slash")
    func endpoint() throws {
        let editor = self.filled()
        let endpoint = try editor.endpoint()
        #expect(endpoint.deviceID == editor.deviceID)
        #expect(endpoint.serverURL.absoluteString == "https://jf.example.test")
    }

    @Test("the bitrate control is enabled only when a format other than Original is chosen")
    func bitrateEnabled() {
        var editor = Editor()
        #expect(editor.preferredFormat == .original)
        #expect(!editor.isBitrateEnabled)
        editor.preferredFormat = .opus
        #expect(editor.isBitrateEnabled)
    }

    @Test("a new server takes the typed name, or the server's own name when blank, and keeps every option")
    func makeServer() {
        var editor = self.filled()
        editor.allowSelfSignedTLS = true
        editor.preferredFormat = .mp3
        editor.bitrateKind = .kbps
        editor.bitrateKbps = 192
        editor.precacheNext = false
        editor.includeInGlobalSearch = false
        editor.showInSidebar = false
        editor.scrobble = false
        editor.syncStars = false
        let session = JellyfinSession(userID: "u1", username: "chris", accessToken: "T")
        let unnamed = editor.makeServer(session: session, fallbackName: "Basement", sortIndex: 3)
        #expect(unnamed.name == "Basement")
        #expect(unnamed.userID == "u1")
        #expect(unnamed.username == "chris")
        #expect(unnamed.deviceID == editor.deviceID)
        #expect(unnamed.serverURL.absoluteString == "https://jf.example.test")
        #expect(unnamed.allowSelfSignedTLS)
        #expect(unnamed.maxBitrate == .kbps(192))
        #expect(unnamed.preferredFormat == .mp3)
        #expect(!unnamed.precacheNext && !unnamed.includeInGlobalSearch && !unnamed.showInSidebar)
        #expect(!unnamed.scrobble && !unnamed.syncStars)
        #expect(unnamed.sortIndex == 3)
        editor.name = "  Home  "
        #expect(editor.makeServer(session: session, fallbackName: "Basement", sortIndex: 0).name == "Home")
    }

    @Test("applying the editor never changes the id, the device id, the user or the sign-in name")
    func applyKeepsIdentity() throws {
        let original = try JellyfinServer(
            name: "Old",
            serverURL: #require(URL(string: "https://old.example.test")),
            userID: "u1",
            username: "chris",
            deviceID: "DEVICE-1"
        )
        var editor = Editor(server: original)
        editor.name = "New"
        editor.serverURLText = "https://new.example.test"
        editor.preferredFormat = .aac
        var changed = original
        try editor.apply(to: &changed)
        #expect(changed.id == original.id)
        #expect(changed.deviceID == "DEVICE-1")
        #expect(changed.userID == "u1")
        #expect(changed.username == "chris")
        #expect(changed.name == "New")
        #expect(changed.serverURL.host == "new.example.test")
        #expect(changed.preferredFormat == .aac)
        #expect(editor.signedInAs == "chris")
        #expect(editor.username.isEmpty, "the sign-in field starts empty for a saved server")
        #expect(editor.password.isEmpty)
    }
}

// MARK: - Sign-in flow

@Suite("JellyfinSettingsViewModel sign-in", .serialized)
@MainActor
struct JellyfinSettingsViewModelTests {
    private func fill(_ vm: JellyfinSettingsViewModel, name: String = "") {
        vm.beginAddServer()
        vm.editor.name = name
        vm.editor.serverURLText = "https://jf.example.test"
        vm.editor.username = "chris"
        vm.editor.password = "hunter2"
    }

    @Test("a wrong password shows the server's reason, stores nothing and still clears the password")
    func wrongPassword() async throws {
        let auth = StubAuth()
        auth.signInResult = .failure(.unauthorized)
        let harness = try await makeHarness(auth: auth)
        self.fill(harness.vm)
        await harness.vm.signInWithPassword()
        #expect(harness.vm.errorMessage != nil)
        #expect(harness.vm.editor.password.isEmpty, "the password must not stay in the form")
        #expect(try await harness.store.fetchAll().isEmpty)
        #expect(harness.vm.isAddingNew, "the draft stays open so the user can try again")
        #expect(harness.changed.value == 0)
        #expect(!harness.vm.isSigningIn)
    }

    @Test("sign-in with a bad address never reaches the server")
    func badAddress() async throws {
        let harness = try await makeHarness()
        self.fill(harness.vm)
        harness.vm.editor.serverURLText = "not a url"
        await harness.vm.signInWithPassword()
        #expect(harness.vm.errorMessage != nil)
        #expect(harness.auth.passwords.isEmpty)
    }

    @Test("Test Server reports the name, the version and whether Quick Connect is on")
    func testServer() async throws {
        let harness = try await makeHarness()
        self.fill(harness.vm)
        await harness.vm.testServer()
        let result = try #require(harness.vm.lastTestResult)
        #expect(result.success)
        #expect(result.serverName == "Basement")
        #expect(result.version == "12.2.0")
        #expect(result.quickConnectAvailable)
        #expect(result.signedIn == nil, "an unsaved server has no sign-in to check")
    }

    @Test("Quick Connect shows the code while it waits, and Cancel hides it and stops waiting")
    func quickConnectCancel() async throws {
        let auth = StubAuth()
        auth.quickConnectEvents = [.waiting(code: "123456")]
        auth.quickConnectHangs = true
        let harness = try await makeHarness(auth: auth)
        self.fill(harness.vm)
        harness.vm.startQuickConnect()
        #expect(await self.eventually { harness.vm.quickConnectCode == "123456" })
        #expect(harness.vm.isSigningIn)
        harness.vm.cancelQuickConnect()
        #expect(harness.vm.quickConnectCode == nil)
        #expect(!harness.vm.isSigningIn)
        #expect(try await harness.store.fetchAll().isEmpty)
    }

    @Test("Quick Connect that the server has switched off shows a message and ends the wait")
    func quickConnectDisabled() async throws {
        let auth = StubAuth()
        auth.quickConnectError = .quickConnectDisabled
        let harness = try await makeHarness(auth: auth)
        self.fill(harness.vm)
        harness.vm.startQuickConnect()
        #expect(await self.eventually { harness.vm.errorMessage != nil && !harness.vm.isSigningIn })
        #expect(harness.vm.quickConnectCode == nil)
    }

    @Test("starting a new draft or picking a server stops a Quick Connect that is still waiting")
    func draftStopsQuickConnect() async throws {
        let auth = StubAuth()
        auth.quickConnectEvents = [.waiting(code: "999000")]
        auth.quickConnectHangs = true
        let harness = try await makeHarness(auth: auth)
        self.fill(harness.vm)
        harness.vm.startQuickConnect()
        #expect(await self.eventually { harness.vm.quickConnectCode == "999000" })
        harness.vm.beginAddServer()
        #expect(harness.vm.quickConnectCode == nil)
        #expect(!harness.vm.isSigningIn)
    }

    // MARK: With the Keychain

    @Test(
        "a password sign-in adds the server under the server's own name, selects it and tells the sidebar",
        .enabled(if: keychainAvailable())
    )
    func addByPassword() async throws {
        let harness = try await makeHarness()
        self.fill(harness.vm)
        await harness.vm.signInWithPassword()
        #expect(harness.vm.errorMessage == nil)
        let saved = try #require(try await harness.store.fetchAll().first)
        #expect(saved.name == "Basement", "a blank display name takes the server's own name")
        #expect(saved.userID == "user-1")
        #expect(saved.username == "chris")
        #expect(harness.auth.passwords.map(\.username) == ["chris"])
        #expect(harness.vm.editor.password.isEmpty)
        #expect(!harness.vm.isAddingNew)
        #expect(harness.vm.selectedServerID == saved.id)
        #expect(harness.vm.servers.map(\.id) == [saved.id])
        #expect(harness.changed.value == 1)
        try await harness.store.remove(id: saved.id)
    }

    @Test("a Quick Connect approval adds the server too", .enabled(if: keychainAvailable()))
    func addByQuickConnect() async throws {
        let auth = StubAuth()
        auth.quickConnectEvents = [
            .waiting(code: "424242"),
            .approved(JellyfinSession(userID: "user-qc", username: "qc-user", accessToken: "TOKEN-QC")),
        ]
        let harness = try await makeHarness(auth: auth)
        self.fill(harness.vm, name: "Living room")
        harness.vm.startQuickConnect()
        #expect(await self.eventually { harness.vm.servers.count == 1 && !harness.vm.isSigningIn })
        let saved = try #require(try await harness.store.fetchAll().first)
        #expect(saved.name == "Living room")
        #expect(saved.username == "qc-user")
        #expect(harness.vm.quickConnectCode == nil)
        try await harness.store.remove(id: saved.id)
    }

    @Test("signing in again keeps the row and its device id and swaps the user", .enabled(if: keychainAvailable()))
    func signInAgain() async throws {
        let harness = try await makeHarness()
        self.fill(harness.vm, name: "Home")
        await harness.vm.signInWithPassword()
        let first = try #require(try await harness.store.fetchAll().first)

        harness.auth.signInResult = .success(JellyfinSession(userID: "user-2", username: "other", accessToken: "TOKEN-2"))
        harness.vm.selectServer(first.id)
        harness.vm.editor.username = "other"
        harness.vm.editor.password = "pw"
        await harness.vm.signInWithPassword()

        let all = try await harness.store.fetchAll()
        #expect(all.count == 1, "signing in again must not add a second row")
        #expect(all[0].id == first.id)
        #expect(all[0].deviceID == first.deviceID, "one device entry on the server")
        #expect(all[0].userID == "user-2")
        #expect(all[0].username == "other")
        try await harness.store.remove(id: first.id)
    }

    @Test("saving changes keeps the sign-in and applies the options", .enabled(if: keychainAvailable()))
    func saveEdits() async throws {
        let harness = try await makeHarness()
        self.fill(harness.vm, name: "Home")
        await harness.vm.signInWithPassword()
        let first = try #require(try await harness.store.fetchAll().first)
        harness.vm.selectServer(first.id)
        harness.vm.editor.name = "Renamed"
        harness.vm.editor.preferredFormat = .opus
        harness.vm.editor.bitrateKind = .kbps
        harness.vm.editor.bitrateKbps = 128
        harness.vm.editor.syncStars = false
        await harness.vm.save()
        let saved = try #require(try await harness.store.fetch(id: first.id))
        #expect(saved.name == "Renamed")
        #expect(saved.preferredFormat == .opus)
        #expect(saved.maxBitrate == .kbps(128))
        #expect(!saved.syncStars)
        #expect(saved.userID == first.userID)
        try await harness.store.remove(id: first.id)
    }

    @Test("two servers with one name are refused and the first stays", .enabled(if: keychainAvailable()))
    func duplicateName() async throws {
        let harness = try await makeHarness()
        self.fill(harness.vm, name: "Home")
        await harness.vm.signInWithPassword()
        self.fill(harness.vm, name: "Home")
        await harness.vm.signInWithPassword()
        #expect(harness.vm.errorMessage != nil)
        let all = try await harness.store.fetchAll()
        #expect(all.count == 1)
        for server in all {
            try await harness.store.remove(id: server.id)
        }
    }

    // MARK: Waiting

    private func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return condition()
            }
        }
        return condition()
    }
}
