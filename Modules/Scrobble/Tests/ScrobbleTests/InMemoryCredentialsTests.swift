import Foundation
import Testing
@testable import Scrobble

@Suite("InMemoryCredentials")
struct InMemoryCredentialsTests {
    @Test("seed populates initial values")
    func seedInit() async {
        let creds = InMemoryCredentials(seed: ["a": "1", "b": "two"])
        #expect(await creds.string(for: "a") == "1")
        #expect(await creds.string(for: "b") == "two")
        #expect(await Set(creds.allAccounts()) == Set(["a", "b"]))
    }

    @Test("set and read string round-trip")
    func setString() async {
        let creds = InMemoryCredentials()
        await creds.set("hello", for: "k")
        #expect(await creds.string(for: "k") == "hello")
        #expect(await creds.data(for: "k") == Data("hello".utf8))
    }

    @Test("set and read data round-trip")
    func setData() async {
        let creds = InMemoryCredentials()
        let payload = Data([0x01, 0x02, 0x03])
        await creds.set(payload, for: "blob")
        #expect(await creds.data(for: "blob") == payload)
    }

    @Test("remove deletes account")
    func remove() async {
        let creds = InMemoryCredentials(seed: ["a": "1"])
        await creds.remove(account: "a")
        #expect(await creds.string(for: "a") == nil)
        #expect(await creds.allAccounts().isEmpty)
    }

    @Test("missing accounts return nil")
    func missing() async {
        let creds = InMemoryCredentials()
        #expect(await creds.string(for: "nope") == nil)
        #expect(await creds.data(for: "nope") == nil)
    }
}
