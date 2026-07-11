import Foundation
import Testing
@testable import SyncServer

@Suite("Gzip")
struct GzipTests {
    private func sample() -> Data {
        Data(String(repeating: "{\"key\":\"value\",\"n\":12345}", count: 300).utf8)
    }

    @Test("output passes the system gzip integrity check and round-trips")
    func systemGzipAccepts() throws {
        let original = self.sample()
        let gzipped = try #require(Gzip.compress(original))

        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).gz")
        defer { try? FileManager.default.removeItem(at: file) }
        try gzipped.write(to: file)

        // `gzip -t` validates the magic, CRC-32, ISIZE, and DEFLATE stream; if it
        // passes, any standard gzip decoder (the Android client's) accepts it.
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        test.arguments = ["-t", file.path]
        try test.run()
        test.waitUntilExit()
        #expect(test.terminationStatus == 0)

        // Decompress with the system tool and compare to the original.
        let decompress = Process()
        decompress.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        decompress.arguments = ["-dc", file.path]
        let pipe = Pipe()
        decompress.standardOutput = pipe
        try decompress.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        decompress.waitUntilExit()
        #expect(output == original)
    }

    @Test("header, trailer, and DEFLATE payload are well-formed")
    func structure() throws {
        let original = self.sample()
        let gzipped = try #require(Gzip.compress(original))

        #expect(Array(gzipped.prefix(3)) == [0x1F, 0x8B, 0x08])

        let inflated = try #require(TestGunzip.inflate(gzipped))
        #expect(inflated == original)

        let trailer = Array(gzipped.suffix(8))
        let crc = UInt32(trailer[0]) | (UInt32(trailer[1]) << 8) | (UInt32(trailer[2]) << 16) | (UInt32(trailer[3]) << 24)
        let isize = UInt32(trailer[4]) | (UInt32(trailer[5]) << 8) | (UInt32(trailer[6]) << 16) | (UInt32(trailer[7]) << 24)
        #expect(crc == Gzip.crc32(original))
        #expect(isize == UInt32(original.count))
    }

    @Test("compressible data gets smaller")
    func shrinks() throws {
        let original = self.sample()
        let gzipped = try #require(Gzip.compress(original))
        #expect(gzipped.count < original.count)
    }

    @Test("CRC-32 matches the known check value for \"123456789\"")
    func crc32CheckValue() {
        // The IEEE CRC-32 check value for the ASCII string "123456789".
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
