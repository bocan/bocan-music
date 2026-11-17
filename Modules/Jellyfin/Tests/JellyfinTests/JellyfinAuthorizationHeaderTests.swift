import Foundation
import Testing
@testable import Jellyfin

/// The SDK builds the `Authorization` header from a dictionary, unquoted and in a
/// new field order on each request, and CFNetwork cuts a header at its first
/// non-ASCII byte. A computer name with a typographic apostrophe therefore lost
/// the token on about half of all requests. These tests pin the fix: every value
/// the client puts in the header is plain ASCII (docs/GOTCHAS.md).
@Suite("Authorization header values")
struct JellyfinHeaderSafeTests {
    @Test("typographic punctuation and accents become plain ASCII")
    func transliterates() {
        #expect(JellyfinClientIdentity.headerSafe("Chris\u{2019}s MacBook Pro", fallback: "Mac") == "Chris's MacBook Pro")
        #expect(JellyfinClientIdentity.headerSafe("Zo\u{EB}\u{2019}s Mac mini", fallback: "Mac") == "Zoe's Mac mini")
        #expect(JellyfinClientIdentity.headerSafe("Studio \u{2014} Main", fallback: "Mac") == "Studio - Main")
    }

    @Test("characters that would end a header field early are dropped")
    func dropsFieldBreakers() {
        #expect(JellyfinClientIdentity.headerSafe("a, b = \"c\"", fallback: "Mac") == "a b c")
    }

    @Test("anything with no ASCII form is dropped, and an empty result gives the fallback")
    func fallback() {
        #expect(JellyfinClientIdentity.headerSafe("\u{1F3B5}", fallback: "Mac") == "Mac")
        #expect(JellyfinClientIdentity.headerSafe("", fallback: "Mac") == "Mac")
        #expect(JellyfinClientIdentity.headerSafe("  two   spaces  ", fallback: "Mac") == "two spaces")
    }

    @Test("a name in another script still comes out as printable ASCII")
    func otherScripts() {
        let name = JellyfinClientIdentity.headerSafe("\u{5C71}\u{7530}\u{306E}Mac", fallback: "Mac")
        #expect(!name.isEmpty)
        #expect(name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F })
    }

    @Test("this Mac's real identity is header-safe")
    func currentIdentity() {
        let identity = JellyfinClientIdentity.current()
        for value in [identity.client, identity.deviceName, identity.version] {
            #expect(!value.isEmpty)
            #expect(value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F && $0 != "," && $0 != "=" })
        }
    }
}

extension StubbedNetwork {
    @Suite("Authorization header on the wire")
    struct JellyfinAuthorizationHeaderTests {
        @Test("every request carries every field in plain ASCII, whatever order the SDK picks")
        func everyRequestKeepsTheToken() async throws {
            let identity = JellyfinClientIdentity(
                client: "Bocan",
                deviceName: JellyfinClientIdentity.headerSafe("Chris\u{2019}s MacBook Pro", fallback: "Mac"),
                version: "9.9"
            )
            var configuration = JellyfinClientConfiguration.test()
            configuration.identity = identity
            let client = JellyfinSDKClient(
                configuration: configuration,
                sessionConfiguration: StubURLProtocol.sessionConfiguration
            )
            StubURLProtocol.install { _ in StubURLProtocol.Reply(body: Data("{}".utf8)) }
            defer { StubURLProtocol.reset() }

            // The SDK picks a new field order per request, so one request proves little.
            for _ in 0 ..< 25 {
                try await client.ping()
            }
            let headers = StubURLProtocol.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
            #expect(headers.count == 25)
            for header in headers {
                #expect(header.unicodeScalars.allSatisfy { $0.value < 0x80 }, "non-ASCII in \(header.prefix(12))…")
                #expect(header.contains("Token=TEST-TOKEN-0123456789"))
                #expect(header.contains("Client=Bocan"))
                #expect(header.contains("Device=Chris's MacBook Pro"))
                #expect(header.contains("DeviceId=DEVICE-1"))
                #expect(header.contains("Version=9.9"))
            }
        }
    }
}
