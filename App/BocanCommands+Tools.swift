import SwiftUI
import UI

// MARK: - Tools menu

extension BocanCommands {
    /// The Tools menu: library-wide maintenance actions. Extracted from
    /// `BocanCommands.swift` to keep that file under the 500-line lint ceiling.
    var toolsCommands: some Commands {
        CommandMenu("Tools") {
            Button("Fetch Missing Cover Art\u{2026}") {
                self.vm.showBatchCoverArt()
            }
            .help("Search MusicBrainz for cover art for albums with no artwork")

            Button("Find Duplicates\u{2026}") {
                self.vm.showDuplicateReview()
            }
            .help("Find and review tracks that appear more than once in your library")

            Divider()

            Button("Compute Missing ReplayGain") {
                Task { await self.vm.computeMissingReplayGain() }
            }
            .help("Analyse loudness for tracks that don't yet have ReplayGain data")

            Button("Recompute ReplayGain") {
                Task { await self.vm.recomputeAllReplayGain() }
            }
            .help("Re-analyse loudness for every track in the library")
        }
    }
}
