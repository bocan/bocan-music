import CryptoKit
import Foundation
import Testing
@testable import Metadata

@Suite("CoverArtExtractor")
struct CoverArtExtractorTests {
    private func makeArt(bytes: [UInt8] = [0xFF, 0xD8, 0xFF], mime: String = "image/jpeg", type: Int = 3) -> RawCoverArt {
        RawCoverArt(data: Data(bytes), mimeType: mime, pictureType: type)
    }

    @Test("single image is returned")
    func singleImage() {
        let arts = CoverArtExtractor.extract(from: [self.makeArt()])
        #expect(arts.count == 1)
        #expect(arts[0].mimeType == "image/jpeg")
        #expect(arts[0].pictureType == 3)
    }

    @Test("duplicate images are deduped by SHA-256")
    func deduplication() {
        let art = self.makeArt()
        let arts = CoverArtExtractor.extract(from: [art, art])
        #expect(arts.count == 1)
    }

    @Test("different images are both included")
    func multipleDistinctImages() {
        let a = self.makeArt(bytes: [0x01, 0x02])
        let b = self.makeArt(bytes: [0x03, 0x04], type: 0)
        let arts = CoverArtExtractor.extract(from: [a, b])
        #expect(arts.count == 2)
    }

    @Test("front cover (type 3) comes first")
    func frontCoverFirst() {
        let back = self.makeArt(bytes: [0x01], type: 4)
        let front = self.makeArt(bytes: [0x02], type: 3)
        let arts = CoverArtExtractor.extract(from: [back, front])
        #expect(arts[0].pictureType == 3)
    }

    @Test("sha256 field is correct hex digest")
    func sha256Correctness() {
        let data = Data([0x01, 0x02, 0x03])
        let art = CoverArtExtractor.extract(from: [RawCoverArt(data: data, mimeType: "image/jpeg", pictureType: 3)])
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(art[0].sha256 == expected)
    }

    @Test("fileExtension inferred from mimeType")
    func fileExtensions() {
        let cases: [(String, String)] = [
            ("image/jpeg", "jpg"),
            ("image/png", "png"),
            ("image/webp", "webp"),
            ("image/gif", "gif"),
            ("application/octet-stream", "bin"),
        ]
        for (mime, ext) in cases {
            let art = ExtractedCoverArt(data: Data([0x00]), mimeType: mime, pictureType: 3)
            #expect(art.fileExtension == ext)
        }
    }

    @Test("empty input returns empty array")
    func emptyInput() {
        #expect(CoverArtExtractor.extract(from: []).isEmpty)
    }
}
