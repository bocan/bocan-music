import Foundation
import Testing
@testable import SyncServer

// MARK: - SwallowedErrorSyncServerConventionTests

/// #498: the response-send path dropped its error entirely. The usual cause is
/// the phone closing the connection first, which is ordinary, so this is a
/// debug line rather than a warning: enough to explain a truncated transfer
/// when someone goes looking. A log cannot be read back from a test, so the
/// shape is pinned here (`docs/audits/try-optional-audit.md`, class (b)).
@Suite("Swallowed-error conventions in SyncServer (#498)")
struct SwallowedErrorSyncServerConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // SyncServerTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/SyncServer/
            .appendingPathComponent("Sources/SyncServer")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("a response that cannot be written says so, buffered or streamed")
    func sendFailuresAreLogged() throws {
        let source = try self.source("Transport/HttpConnection.swift")
        #expect(!source.contains("try? await self.rawSend("), "the send error was dropped entirely")
        #expect(source.contains("sync.http.sendFailed"))
        // The streamed path's catch was empty: same fault, invisible to a
        // `try?` search, two lines below the site the audit did catch.
        #expect(source.contains("sync.http.streamFailed"))
    }
}
