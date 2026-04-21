import Library
import SwiftUI

// MARK: - TracksView Table definitions

extension TracksView {
    var sortableTable: some View {
        TrackTable(
            rows: self.vm.rows,
            selection: self.$vm.selection,
            sortOrder: self.$sortOrder,
            nowPlayingTrackID: self.nowPlaying.nowPlayingTrackID,
            sortable: true,
            playlistNodes: self.library.playlistSidebar.nodes,
            actions: self.trackContextMenuActions
        )
    }

    var plainTable: some View {
        TrackTable(
            rows: self.vm.rows,
            selection: self.$vm.selection,
            sortOrder: self.$sortOrder,
            nowPlayingTrackID: self.nowPlaying.nowPlayingTrackID,
            sortable: false,
            playlistNodes: self.library.playlistSidebar.nodes,
            actions: self.trackContextMenuActions
        )
    }
}
