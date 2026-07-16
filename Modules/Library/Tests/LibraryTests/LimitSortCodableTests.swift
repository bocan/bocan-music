import Foundation
import Testing
@testable import Library

// MARK: - LimitSortCodableTests

@Suite("LimitSort Codable")
struct LimitSortCodableTests {
    // MARK: - Legacy single-key decode

    @Test("Legacy single-key JSON decodes into one descriptor")
    func legacySingleKeyDecodes() throws {
        let json = #"{"sortBy":"rating","ascending":true,"limit":25,"liveUpdate":false}"#
        let data = Data(json.utf8)
        let ls = try JSONDecoder().decode(LimitSort.self, from: data)
        #expect(ls.sortDescriptors == [SmartSortDescriptor(key: .rating, ascending: true)])
        #expect(ls.sortBy == .rating)
        #expect(ls.ascending == true)
        #expect(ls.limit == 25)
        #expect(ls.liveUpdate == false)
    }

    @Test("Legacy JSON with no sort fields falls back to a single default descriptor")
    func legacyMissingSortFallsBack() throws {
        let json = #"{"liveUpdate":true}"#
        let data = Data(json.utf8)
        let ls = try JSONDecoder().decode(LimitSort.self, from: data)
        #expect(ls.sortDescriptors == [SmartSortDescriptor(key: .addedAt, ascending: false)])
    }

    // MARK: - Multi-key roundtrip

    @Test("Multi-key descriptors survive an encode/decode roundtrip in order")
    func multiKeyRoundtrips() throws {
        let original = LimitSort(sortDescriptors: [
            SmartSortDescriptor(key: .artist, ascending: true),
            SmartSortDescriptor(key: .trackNumber, ascending: true),
            SmartSortDescriptor(key: .title, ascending: false),
        ], limit: 100, liveUpdate: true)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LimitSort.self, from: data)
        #expect(decoded == original)
        #expect(decoded.sortDescriptors.map(\.key) == [.artist, .trackNumber, .title])
    }

    @Test("Encoded JSON mirrors the primary key into the legacy scalar fields")
    func encodesLegacyMirror() throws {
        let ls = LimitSort(sortDescriptors: [
            SmartSortDescriptor(key: .artist, ascending: true),
            SmartSortDescriptor(key: .title, ascending: false),
        ])
        let data = try JSONEncoder().encode(ls)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sortBy"] as? String == "artist")
        #expect(object["ascending"] as? Bool == true)
    }

    // MARK: - Scalar accessor back-compat

    @Test("Scalar sortBy/ascending mutate the primary descriptor")
    func scalarAccessorsMutatePrimary() {
        var ls = LimitSort(sortDescriptors: [
            SmartSortDescriptor(key: .artist, ascending: true),
            SmartSortDescriptor(key: .title, ascending: false),
        ])
        ls.sortBy = .rating
        ls.ascending = false
        #expect(ls.sortDescriptors[0] == SmartSortDescriptor(key: .rating, ascending: false))
        // Tie-breaker is untouched.
        #expect(ls.sortDescriptors[1] == SmartSortDescriptor(key: .title, ascending: false))
    }
}
