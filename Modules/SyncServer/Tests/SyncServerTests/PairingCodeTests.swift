import Foundation
import Testing
@testable import SyncServer

/// Golden-vector suite for `PairingCode`. The fixture `pairing-vectors.json` is
/// copied byte-identical from the Android repo
/// (`core/sync/src/test/resources/fixtures/pairing-vectors.json`); if the Mac
/// reproduces every vector, the two implementations of `sync-protocol.md`
/// section 4 provably agree. This is the cross-repo compatibility canary: it must
/// stay green in both repos.
struct PairingCodeTests {
    /// One golden vector from the shared fixture. A non-public struct of
    /// immutable `String` fields is implicitly `Sendable`, which the
    /// parameterized tests rely on for the `arguments:` collection.
    struct Vector: Decodable {
        let fpMac: String
        let fpPhone: String
        let noncePhoneBase64: String
        let nonceMacBase64: String
        let expectedCode: String
        let sessionId: String
        let expectedProofBase64: String
    }

    private struct Fixture: Decodable {
        let vectors: [Vector]
    }

    /// Loaded once for the parameterized tests. Empty only if the fixture is
    /// missing or malformed, which `fixtureLoaded` fails loudly on.
    static let allVectors: [Vector] = (try? Self.loadVectors()) ?? []

    private static func loadVectors() throws -> [Vector] {
        let url = try #require(
            Bundle.module.url(
                forResource: "pairing-vectors",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            "pairing-vectors.json fixture is not bundled with the test target"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data).vectors
    }

    // MARK: - Fixture presence

    @Test("the shared fixture provides the five golden vectors")
    func fixtureLoaded() {
        #expect(Self.allVectors.count == 5)
    }

    // MARK: - Parity with the golden vectors

    @Test("code() reproduces the golden verification code", arguments: PairingCodeTests.allVectors)
    func codeMatchesGolden(_ vector: Vector) throws {
        let noncePhone = try #require(Data(base64Encoded: vector.noncePhoneBase64))
        let nonceMac = try #require(Data(base64Encoded: vector.nonceMacBase64))
        let code = PairingCode.code(
            fpMac: vector.fpMac,
            fpPhone: vector.fpPhone,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        #expect(code == vector.expectedCode)
    }

    @Test("proof() reproduces the golden confirm proof", arguments: PairingCodeTests.allVectors)
    func proofMatchesGolden(_ vector: Vector) {
        let proof = PairingCode.proof(code: vector.expectedCode, sessionId: vector.sessionId)
        #expect(proof == vector.expectedProofBase64)
    }

    // MARK: - Algebraic properties

    @Test("code() is symmetric in the two fingerprints", arguments: PairingCodeTests.allVectors)
    func codeIsSymmetric(_ vector: Vector) throws {
        let noncePhone = try #require(Data(base64Encoded: vector.noncePhoneBase64))
        let nonceMac = try #require(Data(base64Encoded: vector.nonceMacBase64))
        let asMac = PairingCode.code(
            fpMac: vector.fpMac,
            fpPhone: vector.fpPhone,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        let swapped = PairingCode.code(
            fpMac: vector.fpPhone,
            fpPhone: vector.fpMac,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        #expect(asMac == swapped)
        #expect(asMac == vector.expectedCode)
    }

    @Test("code() is deterministic for identical inputs")
    func codeIsDeterministic() throws {
        let vector = try #require(Self.allVectors.first)
        let noncePhone = try #require(Data(base64Encoded: vector.noncePhoneBase64))
        let nonceMac = try #require(Data(base64Encoded: vector.nonceMacBase64))
        let first = PairingCode.code(
            fpMac: vector.fpMac,
            fpPhone: vector.fpPhone,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        let second = PairingCode.code(
            fpMac: vector.fpMac,
            fpPhone: vector.fpPhone,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        #expect(first == second)
    }

    // MARK: - Sensitivity (guards against a degenerate implementation)

    @Test("flipping a fingerprint character changes the code")
    func fingerprintSensitivity() throws {
        let vector = try #require(Self.allVectors.first)
        let noncePhone = try #require(Data(base64Encoded: vector.noncePhoneBase64))
        let nonceMac = try #require(Data(base64Encoded: vector.nonceMacBase64))
        let base = PairingCode.code(
            fpMac: vector.fpMac,
            fpPhone: vector.fpPhone,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        let changed = PairingCode.code(
            fpMac: Self.flipLastCharacter(vector.fpMac),
            fpPhone: vector.fpPhone,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        #expect(base != changed)
    }

    @Test("flipping a nonce byte changes the code")
    func nonceSensitivity() throws {
        let vector = try #require(Self.allVectors.first)
        let noncePhone = try #require(Data(base64Encoded: vector.noncePhoneBase64))
        let nonceMac = try #require(Data(base64Encoded: vector.nonceMacBase64))
        var mutated = noncePhone
        mutated[mutated.startIndex] ^= 0x01
        let base = PairingCode.code(
            fpMac: vector.fpMac,
            fpPhone: vector.fpPhone,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        let changed = PairingCode.code(
            fpMac: vector.fpMac,
            fpPhone: vector.fpPhone,
            noncePhone: mutated,
            nonceMac: nonceMac
        )
        #expect(base != changed)
    }

    /// Replace the final character with a different lowercase hex digit so the
    /// returned string always differs from the input.
    private static func flipLastCharacter(_ value: String) -> String {
        var characters = Array(value)
        guard let last = characters.last else { return value }
        characters[characters.count - 1] = (last == "0") ? "1" : "0"
        return String(characters)
    }
}
