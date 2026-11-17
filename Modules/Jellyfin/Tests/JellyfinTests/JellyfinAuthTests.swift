import Foundation
import Testing
@testable import Jellyfin

@Suite("JellyfinAuth")
struct JellyfinAuthTests {
    private func endpoint() throws -> JellyfinEndpoint {
        try JellyfinEndpoint(serverURL: #require(URL(string: "https://jf.example.test/")), deviceID: "DEVICE-1")
    }

    private func auth(_ stub: StubAuthClient, sleeps: Locked<[Duration]> = Locked([])) -> JellyfinAuth {
        JellyfinAuth(
            identity: JellyfinClientIdentity(client: "Bocan", deviceName: "Test", version: "1"),
            makeClient: { _ in stub },
            sleep: { duration in
                sleeps.update { $0.append(duration) }
                try Task.checkCancellation()
            }
        )
    }

    private func collect(_ stream: AsyncThrowingStream<JellyfinQuickConnectEvent, Error>) async
        -> (events: [JellyfinQuickConnectEvent], error: (any Error)?) {
        var events: [JellyfinQuickConnectEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    // MARK: Endpoint

    @Test("an endpoint strips trailing slashes")
    func endpointNormalises() throws {
        #expect(try self.endpoint().serverURL.absoluteString == "https://jf.example.test")
    }

    @Test(
        "an endpoint rejects a bad scheme and a missing host",
        arguments: ["ftp://jf.example.test", "jf.example.test", "https://", "file:///tmp"]
    )
    func endpointRejects(text: String) {
        #expect(throws: JellyfinError.self) {
            _ = try JellyfinEndpoint(serverURL: #require(URL(string: text)), deviceID: "D")
        }
    }

    // MARK: Probe and password

    @Test("probe asks for the public server info with no sign-in")
    func probe() async throws {
        let stub = StubAuthClient()
        let info = try await self.auth(stub).probe(self.endpoint())
        #expect(info.version == "10.10.7")
        #expect(stub.calls.value == ["serverInfo"])
    }

    @Test("password sign-in returns the session the client gave")
    func signIn() async throws {
        let stub = StubAuthClient()
        let session = try await self.auth(stub).signIn(self.endpoint(), username: "listener", password: "hunter2")
        #expect(session.userID == "user-1")
        #expect(session.username == "listener")
        #expect(session.accessToken == "token-1")
    }

    @Test("a wrong password surfaces as unauthorized and is not retried")
    func signInRejected() async throws {
        let stub = StubAuthClient()
        stub.onSignIn = { _, _ in throw JellyfinError.unauthorized }
        let auth = self.auth(stub)
        let endpoint = try self.endpoint()
        await #expect(throws: JellyfinError.unauthorized) {
            _ = try await auth.signIn(endpoint, username: "listener", password: "wrong")
        }
        #expect(stub.calls.value == ["signIn"])
    }

    @Test("Quick Connect availability: on, off, and a server that does not answer counts as off")
    func quickConnectAvailable() async throws {
        let stub = StubAuthClient()
        let auth = self.auth(stub)
        let endpoint = try self.endpoint()
        #expect(await auth.quickConnectAvailable(endpoint))
        stub.quickConnectOn = false
        #expect(await !auth.quickConnectAvailable(endpoint))
    }

    // MARK: Quick Connect

    @Test("Quick Connect shows the code, polls until approved, then signs in")
    func quickConnectApproved() async throws {
        let stub = StubAuthClient()
        stub.pollAnswers = [.success(false), .success(false), .success(true)]
        let sleeps = Locked<[Duration]>([])
        let result = try await self.collect(self.auth(stub, sleeps: sleeps).quickConnect(self.endpoint()))
        #expect(result.error == nil)
        #expect(result.events.count == 2)
        guard case let .waiting(code) = result.events[0] else { Issue.record("expected .waiting first")
            return
        }
        #expect(code == "123456")
        guard case let .approved(session) = result.events[1] else { Issue.record("expected .approved second")
            return
        }
        #expect(session.accessToken == "token-qc")
        #expect(stub.calls.value == ["quickConnectEnabled", "initiate", "poll", "poll", "poll", "signInApproved"])
        // It waits before each poll, five seconds by default.
        #expect(sleeps.value == [.seconds(5), .seconds(5), .seconds(5)])
    }

    @Test("Quick Connect off on the server throws quickConnectDisabled and never asks for a code")
    func quickConnectDisabled() async throws {
        let stub = StubAuthClient()
        stub.quickConnectOn = false
        let result = try await self.collect(self.auth(stub).quickConnect(self.endpoint()))
        #expect(result.events.isEmpty)
        #expect(result.error as? JellyfinError == .quickConnectDisabled)
        #expect(stub.calls.value == ["quickConnectEnabled"])
    }

    @Test("Quick Connect gives up after the maximum number of polls with a timeout error")
    func quickConnectTimesOut() async throws {
        let stub = StubAuthClient()
        stub.pollAnswers = [.success(false)]
        let policy = JellyfinQuickConnectPolicy(interval: .seconds(1), maxPolls: 4, failureTolerance: 5)
        let result = try await self.collect(self.auth(stub).quickConnect(self.endpoint(), policy: policy))
        #expect(result.events.count == 1) // the code was shown
        #expect(result.error as? JellyfinError == .quickConnectTimedOut)
        #expect(stub.calls.value.filter { $0 == "poll" }.count == 4)
        #expect(!stub.calls.value.contains("signInApproved"))
    }

    @Test("a poll that fails now and then is tolerated; a run of failures ends the sign-in")
    func quickConnectFailureTolerance() async throws {
        let blip: Result<Bool, any Error> = .failure(JellyfinError.network("blip"))
        let tolerant = StubAuthClient()
        tolerant.pollAnswers = [blip, .success(false), blip, .success(true)]
        let ok = try await self.collect(self.auth(tolerant).quickConnect(self.endpoint()))
        #expect(ok.error == nil)
        #expect(ok.events.count == 2)

        let broken = StubAuthClient()
        broken.pollAnswers = [blip]
        let policy = JellyfinQuickConnectPolicy(interval: .seconds(1), maxPolls: 50, failureTolerance: 2)
        let failed = try await self.collect(self.auth(broken).quickConnect(self.endpoint(), policy: policy))
        #expect(failed.error as? JellyfinError == .network("blip"))
        // Tolerance 2 means the third failure in a row ends it.
        #expect(broken.calls.value.filter { $0 == "poll" }.count == 3)
    }

    @Test("cancelling the reader stops polling")
    func quickConnectCancelled() async throws {
        let stub = StubAuthClient()
        stub.pollAnswers = [.success(false)]
        let gate = Locked(false)
        let auth = JellyfinAuth(
            identity: JellyfinClientIdentity(client: "Bocan", deviceName: "Test", version: "1"),
            makeClient: { _ in stub },
            sleep: { _ in
                // Wait until cancelled, as a real sleep would.
                while !gate.value {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        )
        let endpoint = try self.endpoint()
        let reader = Task {
            var count = 0
            for try await _ in auth.quickConnect(endpoint) {
                count += 1
            }
            return count
        }
        // Let the code be shown and the first sleep begin.
        try await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        let events = try await reader.value
        #expect(events == 1)
        let pollsAtCancel = stub.calls.value.filter { $0 == "poll" }.count
        try await Task.sleep(for: .milliseconds(100))
        gate.update { $0 = true }
        #expect(stub.calls.value.filter { $0 == "poll" }.count == pollsAtCancel)
        #expect(!stub.calls.value.contains("signInApproved"))
    }

    @Test("a code that cannot be made throws and shows nothing")
    func quickConnectInitiateFails() async throws {
        let stub = StubAuthClient()
        stub.onInitiate = { throw JellyfinError.http(status: 500) }
        let result = try await self.collect(self.auth(stub).quickConnect(self.endpoint()))
        #expect(result.events.isEmpty)
        #expect(result.error as? JellyfinError == .http(status: 500))
    }
}
