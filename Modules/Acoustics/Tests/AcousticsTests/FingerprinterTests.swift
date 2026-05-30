import Foundation
import Testing
@testable import Acoustics

@Suite("Fingerprinter")
struct FingerprinterTests {
    // MARK: - fpcalc output parsing

    @Test("parseFpcalcOutput decodes valid JSON")
    func parsesValidJSON() throws {
        let json = #"{"fingerprint":"AQAAZ0mkUYpGHQ==","duration":259}"#
        let data = Data(json.utf8)
        let (fingerprint, duration) = try Fingerprinter.parseFpcalcOutput(data)
        #expect(fingerprint == "AQAAZ0mkUYpGHQ==")
        #expect(duration == 259)
    }

    @Test("parseFpcalcOutput throws invalidResponse on garbage input")
    func throwsOnGarbage() {
        let data = Data("not json at all".utf8)
        #expect(throws: AcousticsError.self) {
            try Fingerprinter.parseFpcalcOutput(data)
        }
    }

    @Test("parseFpcalcOutput throws invalidResponse on empty data")
    func throwsOnEmpty() {
        #expect(throws: AcousticsError.self) {
            try Fingerprinter.parseFpcalcOutput(Data())
        }
    }

    @Test("parseFpcalcOutput round-trips a known fingerprint")
    func roundTrip() throws {
        let expected = "AQAAkklSRUmSREmUREmUREmUREmUREmU"
        let json = "{\"fingerprint\":\"\(expected)\",\"duration\":180}"
        let (fp, dur) = try Fingerprinter.parseFpcalcOutput(Data(json.utf8))
        #expect(fp == expected)
        #expect(dur == 180)
    }

    // MARK: - Input validation (#294)

    @Test("non-file URL throws invalidInput before touching fpcalc")
    func nonFileURLThrows() async throws {
        let fpcalc = URL(fileURLWithPath: "/nonexistent/fpcalc")
        let fingerprinter = Fingerprinter(fpcalcURL: fpcalc)
        let httpsURL = try #require(URL(string: "https://example.com/audio.mp3"))
        await #expect(throws: AcousticsError.invalidInput(reason: "fpcalc requires a file URL, got: https")) {
            try await fingerprinter.fingerprint(url: httpsURL)
        }
    }

    @Test("path containing NUL byte throws invalidInput before touching fpcalc")
    func nulBytePathThrows() async {
        let fpcalc = URL(fileURLWithPath: "/nonexistent/fpcalc")
        let fingerprinter = Fingerprinter(fpcalcURL: fpcalc)
        // Build a URL whose decoded path contains a NUL via percent-encoding.
        // URL(fileURLWithPath:) rejects embedded NUL in a String literal, so we
        // construct the path programmatically.
        var pathWithNul = "/tmp/audio"
        pathWithNul.append(Character(UnicodeScalar(0)))
        pathWithNul.append(contentsOf: ".mp3")
        let nulURL = URL(fileURLWithPath: pathWithNul)
        await #expect(throws: AcousticsError.invalidInput(reason: "file path contains a NUL byte")) {
            try await fingerprinter.fingerprint(url: nulURL)
        }
    }

    // MARK: - Non-zero exit code

    @Test("fpcalcFailed is thrown when fpcalc binary is absent")
    func throwsWhenFpcalcMissing() async {
        let missingURL = URL(fileURLWithPath: "/nonexistent/fpcalc")
        let fingerprinter = Fingerprinter(fpcalcURL: missingURL)
        let audioURL = URL(fileURLWithPath: "/tmp/test.mp3")
        await #expect(throws: (any Error).self) {
            try await fingerprinter.fingerprint(url: audioURL)
        }
    }
}
