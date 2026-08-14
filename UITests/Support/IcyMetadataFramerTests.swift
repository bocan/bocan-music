import XCTest

// MARK: - IcyMetadataFramerTests

/// Pure byte-math coverage for `IcyMetadataFramer`, run without a live
/// socket or app launch — the fast, cheap layer to get right before trusting
/// FFmpeg's ICY reader to make sense of it over the network.
final class IcyMetadataFramerTests: XCTestCase {
    func testNilTitleIsTheSingleUnchangedByte() {
        XCTAssertEqual(IcyMetadataFramer.frame(title: nil), Data([0x00]))
    }

    func testEmptyTitleIsTreatedAsUnchanged() {
        XCTAssertEqual(IcyMetadataFramer.frame(title: ""), Data([0x00]))
    }

    func testShortTitlePadsToTheNext16ByteBoundary() {
        // "StreamTitle='A';" is 16 bytes exactly (a good edge case: the
        // "no extra padding needed" boundary).
        let frame = IcyMetadataFramer.frame(title: "A")
        let text = "StreamTitle='A';"
        XCTAssertEqual(text.utf8.count, 16, "fixture assumption: exactly one 16-byte block")
        XCTAssertEqual(frame.first, 1, "length byte must be blockSize / 16")
        XCTAssertEqual(frame.count, 1 + 16)
        XCTAssertEqual(Array(frame.dropFirst()), Array(text.utf8))
    }

    func testLongerTitlePadsWithTrailingNULsToTheBlockBoundary() {
        let title = "Test FM - Track One"
        let frame = IcyMetadataFramer.frame(title: title)
        let text = "StreamTitle='\(title)';"
        let expectedPadded = ((text.utf8.count + 15) / 16) * 16

        XCTAssertEqual(frame.first, UInt8(expectedPadded / 16))
        XCTAssertEqual(frame.count, 1 + expectedPadded)

        let body = Array(frame.dropFirst())
        XCTAssertEqual(Array(body.prefix(text.utf8.count)), Array(text.utf8))
        XCTAssertTrue(
            body.dropFirst(text.utf8.count).allSatisfy { $0 == 0 },
            "padding bytes must be NUL"
        )
    }

    func testSingleQuotesAreDoubledSinceICYHasNoStandardEscaping() throws {
        let frame = IcyMetadataFramer.frame(title: "Rock 'n' Roll")
        let decoded = try XCTUnwrap(String(bytes: frame.dropFirst(), encoding: .utf8))
        XCTAssertTrue(decoded.hasPrefix("StreamTitle='Rock ''n'' Roll';"))
    }

    func testFrameIsAlwaysAWholeNumberOfBlocksAfterTheLengthByte() {
        for title in ["", "A", "A very long station title with lots of characters in it, more than 32", "🎵 Unicode Title 🎶"] {
            let frame = IcyMetadataFramer.frame(title: title)
            guard let lengthByte = frame.first else {
                XCTFail("frame must never be empty")
                continue
            }
            XCTAssertEqual(
                frame.count,
                1 + Int(lengthByte) * 16,
                "declared length byte must match the actual trailing byte count exactly"
            )
        }
    }
}
