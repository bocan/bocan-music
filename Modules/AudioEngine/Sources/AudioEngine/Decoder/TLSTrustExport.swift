import Foundation
import Observability
import Security

// MARK: - TLSTrustExport

/// Makes FFmpeg's TLS certificate verification work under the app sandbox.
///
/// FFmpeg 9 verifies TLS certificates by default. Its OpenSSL backend loads
/// the default verify paths, which resolve to Homebrew's
/// `/opt/homebrew/etc/openssl@3` — unreadable inside the sandbox, so every
/// verified handshake fails. Passing `verify=0` per open is not enough:
/// FFmpeg's HLS demuxer opens variant playlists and media segments as child
/// connections that do not inherit per-open TLS options, so nested opens
/// verify (and fail) regardless.
///
/// The fix is process-wide: export the macOS system trust store (Apple-kept,
/// always current) to a PEM bundle inside the app container and point
/// OpenSSL at it via `SSL_CERT_FILE`, which `SSL_CTX_set_default_verify_paths`
/// honours on every connection, nested ones included. Verification stays ON.
enum TLSTrustExport {
    /// Idempotent: the first call exports and sets the environment variable;
    /// later calls are free. A failed export logs and leaves the environment
    /// untouched (handshakes then fail exactly as before, no worse).
    static func ensureOnce() {
        _ = self.exported
    }

    private static let exported: Void = {
        let log = AppLogger.make(.audio)
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = appSupport.appendingPathComponent("Bocan", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pemURL = dir.appendingPathComponent("system-roots.pem")
            let (pem, count) = try Self.systemRootsPEM()
            try Data(pem.utf8).write(to: pemURL, options: .atomic)
            setenv("SSL_CERT_FILE", pemURL.path, 1)
            log.debug("tls.trust.exported", ["roots": count, "path": pemURL.path])
        } catch {
            log.warning("tls.trust.exportFailed", ["error": String(reflecting: error)])
        }
    }()

    /// The system anchor certificates as one concatenated PEM string, plus
    /// the certificate count. Internal for unit testing.
    static func systemRootsPEM() throws -> (pem: String, count: Int) {
        var anchors: CFArray?
        let status = SecTrustCopyAnchorCertificates(&anchors)
        guard status == errSecSuccess, let anchors else {
            throw AudioEngineError.decoderFailure(
                codec: "TLS",
                underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            )
        }
        var pem = ""
        var count = 0
        for index in 0 ..< CFArrayGetCount(anchors) {
            guard let ptr = CFArrayGetValueAtIndex(anchors, index) else { continue }
            let cert = Unmanaged<SecCertificate>.fromOpaque(ptr).takeUnretainedValue()
            let der = SecCertificateCopyData(cert) as Data
            // endLineWithLineFeed terminates every 64-char line EXCEPT a
            // final partial one, so the newline before END must be ensured
            // by hand or OpenSSL rejects the block (and with it the whole
            // bundle — the bug that broke all TLS playback on 2026-08-16).
            var b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            if !b64.hasSuffix("\n") { b64 += "\n" }
            pem += "-----BEGIN CERTIFICATE-----\n\(b64)-----END CERTIFICATE-----\n"
            count += 1
        }
        return (pem, count)
    }
}
