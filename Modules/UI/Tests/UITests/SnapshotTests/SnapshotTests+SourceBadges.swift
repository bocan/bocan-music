import AppKit
import AudioEngine
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Persistence
@testable import UI

// MARK: - Source badge snapshots (ADR-092)

extension UISnapshotTests {
    @Suite("Source Badge Snapshots")
    @MainActor
    struct SourceBadgeSnapshotTests {
        @Test("Strip with source badges light mode")
        func stripWithSourceBadgesLight() async throws {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            // The codec only ever comes from the decoder, so the fake names
            // one and the `.ready` below is what makes the view model ask.
            engine.storedCodec = "flac"
            let vm = NowPlayingViewModel(engine: engine, database: db)
            let libraryVM = LibraryViewModel(database: db, engine: engine)
            let vizVM = VisualizerViewModel(engine: AudioEngine())
            let now = Int64(Date().timeIntervalSince1970)
            var track = Track(
                fileURL: "file:///tmp/badges.flac",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "flac",
                duration: 300,
                title: "Here Comes the Sun",
                addedAt: now,
                updatedAt: now
            )
            track.bitrate = 1411
            track.sampleRate = 44100
            track.bitDepth = 16
            track.channelCount = 2
            vm.setCurrentTrack(track)
            engine.emit(.ready)
            let deadline = Date().addingTimeInterval(5)
            while vm.sourceFacts?.codec == nil, Date() < deadline {
                await Task.yield()
            }
            // Wider than the other strip cases on purpose: the row drops
            // badges from the end when the title block is squeezed, and the
            // case worth a reference image is the one where all five show.
            // 1200 pt is inside the app's 1100 pt default window.
            let size = CGSize(width: 1200, height: Theme.nowPlayingStripHeight)
            let view = NowPlayingStrip(vm: vm)
                .environmentObject(vizVM)
                .environmentObject(libraryVM)
                .environment(DSPViewModel(engine: AudioEngine()))
                .frame(width: size.width, height: size.height)
            assertSnapshot(
                of: host(view, size: size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "strip-with-source-badges-light"
            )
        }
    }
}
