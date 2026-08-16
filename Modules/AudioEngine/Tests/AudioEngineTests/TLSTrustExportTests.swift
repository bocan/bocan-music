import Foundation
import Testing
@testable import AudioEngine

// MARK: - TLSTrustExportTests

@Suite("TLSTrustExport")
struct TLSTrustExportTests {
    @Test("system roots export to a well-formed, plausibly-sized PEM bundle")
    func systemRootsExport() throws {
        let (pem, count) = try TLSTrustExport.systemRootsPEM()
        // macOS ships well over a hundred root certificates; a dramatically
        // smaller count means the export silently lost most of the store.
        #expect(count > 50, "only \(count) roots exported")
        #expect(pem.contains("-----BEGIN CERTIFICATE-----"))
        #expect(pem.contains("-----END CERTIFICATE-----"))
        // One BEGIN per certificate — the PEM structure must stay aligned
        // with the count or OpenSSL will stop parsing at the first bad block.
        let begins = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
        #expect(begins == count)
        // Every END marker must sit on its own line. Foundation's
        // endLineWithLineFeed leaves a final partial base64 line without a
        // terminator, and an END glued to base64 makes OpenSSL reject the
        // block and with it the entire bundle (the 2026-08-16 all-TLS
        // breakage). Count newline-preceded ENDs — it must match exactly.
        let terminatedEnds = pem.components(separatedBy: "\n-----END CERTIFICATE-----").count - 1
        #expect(terminatedEnds == count, "\(count - terminatedEnds) END markers glued to base64")
    }
}
