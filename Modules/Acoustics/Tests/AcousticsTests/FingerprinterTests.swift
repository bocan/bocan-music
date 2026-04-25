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
