import AppKit
import Testing
@testable import UI

// MARK: - TrackSortChainTests (ADR-093 slice 2)

/// Every key `TrackTable.comparator(from:)` maps, which is the set the table
/// can actually sort by. At file scope because `arguments:` is evaluated
/// outside the suite's main-actor isolation.
private let everySortKey: [String] = [
    "trackNumber", "trackTotal", "discNumber", "discTotal", "databaseID",
    "title", "artistName", "albumName", "genre", "yearText", "duration",
    "playCount", "rating", "lovedSortKey", "addedAt", "fileFormat", "bitrate",
    "sampleRate", "shuffleSortKey", "composer", "bpm", "key", "bitDepth",
    "channelCount", "isLossless", "skipCount", "lastPlayedAt", "fileSize",
    "fileMtime", "musicBrainzID",
]

/// Sorting by one column leaves every tie to the sort algorithm, which for a
/// stat column means equal values scattered in import order. These cover the
/// tie-breakers that sit behind the clicked column.
@Suite("Track sort chains")
@MainActor
struct TrackSortChainTests {
    private func compose(_ clicked: String, ascending: Bool = true) -> [String] {
        TrackSortChain.compose(clicked: NSSortDescriptor(key: clicked, ascending: ascending))
            .compactMap(\.key)
    }

    // MARK: - The default

    @Test("a single click on Artist gives the reading order")
    func artistChain() {
        #expect(self.compose("artistName") == ["artistName", "albumName", "discNumber", "trackNumber"])
    }

    @Test("a stat column keeps its direction and groups the ties")
    func statColumnChain() {
        let chain = TrackSortChain.compose(clicked: NSSortDescriptor(key: "playCount", ascending: false))
        #expect(
            chain.compactMap(\.key) == ["playCount", "artistName", "albumName", "discNumber", "trackNumber"]
        )
        #expect(chain.first?.ascending == false, "the clicked column keeps the direction the user chose")
        // Computed first: a rethrows predicate as the outermost #expect call
        // breaks the Xcode bundle build.
        let descendingTieBreakers = chain.dropFirst().filter { !$0.ascending }
        #expect(
            descendingTieBreakers.isEmpty,
            "tie-breakers are always ascending, or every group reads backwards"
        )
    }

    // MARK: - The overrides

    @Test(
        "each column composes the chain it is documented to",
        arguments: [
            // Overridden: a title sort is not an album reading, so no disc or track.
            ("title", ["title", "artistName", "albumName"]),
            // Overridden: artist before disc and track, because the album
            // column is a title and three artists can share one.
            ("albumName", ["albumName", "artistName", "discNumber", "trackNumber"]),
            // Not overridden: the global chain behind them is already right,
            // and now reaches track rather than stopping at disc.
            ("genre", ["genre", "artistName", "albumName", "discNumber", "trackNumber"]),
            ("yearText", ["yearText", "artistName", "albumName", "discNumber", "trackNumber"]),
        ]
    )
    func documentedChains(clicked: String, expected: [String]) {
        #expect(self.compose(clicked) == expected)
    }

    @Test("disc never appears without track")
    func discNeverAppearsAlone() {
        // Disc on its own sorts nothing a reader can see: it only separates
        // rows that are already equal on track. Which side of track it sits
        // varies legitimately. Behind a clicked column the pair reads disc
        // then track, the album's own order; but clicking Track makes disc the
        // thing that separates disc one's track one from disc two's, so it
        // follows.
        for key in everySortKey {
            let chain = self.compose(key)
            guard chain.contains("discNumber") else { continue }
            #expect(chain.contains("trackNumber"), "\(key): disc appears without track")
        }
    }

    @Test("wherever the pair is offered as tie-breakers, disc leads track")
    func tieBreakerPairIsOrdered() {
        let lists = [TrackSortChain.globalTieBreakers] + Array(TrackSortChain.overrides.values)
        for list in lists {
            guard let disc = list.firstIndex(of: "discNumber") else { continue }
            let track = list.firstIndex(of: "trackNumber")
            #expect(track != nil, "a tie-breaker list offers disc without track")
            if let track {
                #expect(track == disc + 1, "disc and track must be adjacent, disc first")
            }
        }
    }

    @Test("a column inside the global chain needs no override, the dedupe handles it")
    func columnsInsideTheGlobalChain() {
        #expect(self.compose("discNumber").first == "discNumber")
        #expect(self.compose("discNumber").filter { $0 == "discNumber" }.count == 1)
        #expect(self.compose("trackNumber").first == "trackNumber")
        #expect(self.compose("trackNumber").filter { $0 == "trackNumber" }.count == 1)
    }

    @Test("the clicked column leads, and its direction is the only one that varies")
    func clickedColumnLeads() {
        let descending = TrackSortChain.compose(
            clicked: NSSortDescriptor(key: "albumName", ascending: false)
        )
        #expect(descending.first?.key == "albumName")
        #expect(descending.first?.ascending == false)
        #expect(descending.compactMap(\.key) == self.compose("albumName"))
    }

    // MARK: - The sweep

    @Test("every sortable column composes a legal chain", arguments: everySortKey)
    func everyColumnComposesALegalChain(key: String) {
        let chain = self.compose(key)
        #expect(chain.first == key, "the clicked column always leads")
        #expect(Set(chain).count == chain.count, "no key twice")
        #expect(chain.count <= TrackTable.maxSortKeys, "capped")
        #expect(!chain.isEmpty)
    }

    @Test("the sweep covers every key the table maps")
    func sweepIsComplete() {
        // A key added to the table without being added here would sort with
        // the global chain and never be checked.
        for key in everySortKey {
            #expect(
                TrackTable.comparator(from: NSSortDescriptor(key: key, ascending: true)) != nil,
                "\(key) is not a key the table maps; the sweep list has drifted"
            )
        }
    }
}
