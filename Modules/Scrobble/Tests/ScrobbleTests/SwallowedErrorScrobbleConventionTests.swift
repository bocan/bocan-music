import Foundation
import Testing
@testable import Scrobble

// MARK: - SwallowedErrorScrobbleConventionTests

/// #496: five recoveries in this module were correct but silent
/// (`docs/audits/try-optional-audit.md`, class (b)). The recoveries are
/// unchanged; what needs pinning is the log line that explains each one, and a
/// log cannot be read back from a test.
@Suite("Swallowed-error conventions in Scrobble (#496)")
struct SwallowedErrorScrobbleConventionTests {
    private var sourceRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ScrobbleTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/Scrobble/
            .appendingPathComponent("Sources/Scrobble")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("a Keychain failure is logged rather than reported as 'not signed in'")
    func keychainFailuresAreLogged() throws {
        let cases = [
            ("Providers/LastFmProvider.swift", "scrobble.lastfm.keychainReadFailed"),
            ("Providers/ListenBrainzProvider.swift", "scrobble.listenbrainz.keychainReadFailed"),
            ("Providers/RockskyProvider.swift", "scrobble.rocksky.keychainReadFailed"),
        ]
        for (path, event) in cases {
            let source = try self.source(path)
            #expect(source.contains(event), "missing \(event)")
            #expect(!source.contains("try? await self.credentials"), "\(path) still swallows the Keychain error")
        }
    }

    @Test("a 2xx body that will not parse is logged before it becomes an empty reply")
    func unparseableBodiesAreLogged() throws {
        let transport = try self.source("Network/ListenBrainzCompatibleTransport.swift")
        #expect(transport.contains("scrobble.transport.responseDecodeFailed"))
        #expect(!transport.contains("(try? JSONSerialization.jsonObject"))

        let provider = try self.source("Providers/ListenBrainzProvider.swift")
        #expect(provider.contains("scrobble.listenbrainz.validateDecodeFailed"))
        #expect(!provider.contains("try? JSONSerialization.jsonObject"))
    }

    /// This module's allowlist is a single idiom, so it can be asserted
    /// outright: anything else swallowing an error is a regression.
    @Test("every remaining try? in this module is a cancellation-only sleep")
    func onlySleepsSwallow() throws {
        let enumerator = try #require(
            FileManager.default.enumerator(at: self.sourceRoot, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("try?"), !trimmed.hasPrefix("//") else { continue }
                if !trimmed.contains("Task.sleep") {
                    offenders.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        #expect(offenders.isEmpty, "a swallowed error outside the allowlist: \(offenders)")
    }
}
