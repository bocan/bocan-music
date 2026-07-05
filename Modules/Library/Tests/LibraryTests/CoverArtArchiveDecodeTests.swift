import Foundation
import Testing
@testable import Library

// MARK: - CoverArtArchiveDecodeTests

/// CAA serialises image ids as JSON numbers and thumbnail sizes under numeric
/// string keys. Decoding `id` as `String?` with the synthesised decoder threw a
/// type mismatch that a `try?` swallowed, so cover-art search returned zero
/// candidates from the day it shipped. These tests pin the real response shape
/// (trimmed from a live index recorded 2026-07-05).
@Suite("CoverArtArchive decode")
struct CoverArtArchiveDecodeTests {
    /// Real-shape index: numeric `id`, numeric thumbnail keys plus aliases.
    private let realShapeJSON = Data("""
    {
      "images": [
        {
          "approved": true,
          "back": false,
          "comment": "",
          "edit": 115277445,
          "front": true,
          "id": 39706767821,
          "image": "https://coverartarchive.org/release/31765b9f/39706767821.jpg",
          "thumbnails": {
            "1200": "https://coverartarchive.org/release/31765b9f/39706767821-1200.jpg",
            "250": "https://coverartarchive.org/release/31765b9f/39706767821-250.jpg",
            "500": "https://coverartarchive.org/release/31765b9f/39706767821-500.jpg",
            "large": "https://coverartarchive.org/release/31765b9f/39706767821-500.jpg",
            "small": "https://coverartarchive.org/release/31765b9f/39706767821-250.jpg"
          },
          "types": ["Front"]
        }
      ],
      "release": "https://musicbrainz.org/release/31765b9f"
    }
    """.utf8)

    @Test("Numeric image ids decode (the bug that killed cover-art search)")
    func numericIDDecodes() throws {
        let index = try JSONDecoder().decode(CAAIndex.self, from: self.realShapeJSON)
        let image = try #require(index.images.first)
        #expect(image.id == "39706767821")
        #expect(image.front)
        #expect(image.imageURL != nil)
    }

    @Test("String image ids are still accepted")
    func stringIDDecodes() throws {
        let json = Data("""
        {"images": [{"back": false, "front": true, "id": "abc-123",
          "image": "https://example.com/a.jpg", "thumbnails": {}}]}
        """.utf8)
        let index = try JSONDecoder().decode(CAAIndex.self, from: json)
        #expect(index.images.first?.id == "abc-123")
    }

    @Test("Absent id decodes as nil rather than failing the index")
    func absentIDDecodes() throws {
        let json = Data("""
        {"images": [{"back": false, "front": true,
          "image": "https://example.com/a.jpg", "thumbnails": {}}]}
        """.utf8)
        let index = try JSONDecoder().decode(CAAIndex.self, from: json)
        #expect(index.images.first?.id == nil)
    }

    @Test("Thumbnail resolution prefers 500px as documented")
    func thumbnailPrefers500() throws {
        let index = try JSONDecoder().decode(CAAIndex.self, from: self.realShapeJSON)
        let image = try #require(index.images.first)
        #expect(image.thumbnailURL?.absoluteString.hasSuffix("-500.jpg") == true)
    }
}
