import Persistence
import SwiftUI

// MARK: - TracksView Table definitions

extension TracksView {
    var sortableTable: some View {
        Table(
            self.vm.rows,
            selection: self.$vm.selection,
            sortOrder: self.$sortOrder,
            columnCustomization: self.$columnCustomization
        ) {
            self.sortableColumnsLeft
            self.sortableColumnsRight
        }
        .modifier(self.tableChromeModifier)
    }

    var plainTable: some View {
        Table(
            self.vm.rows,
            selection: self.$vm.selection,
            columnCustomization: self.$columnCustomization
        ) {
            self.plainColumnsLeft
            self.plainColumnsRight
        }
        .modifier(self.tableChromeModifier)
    }

    // MARK: Sortable columns

    @TableColumnBuilder<TrackRow, KeyPathComparator<TrackRow>>
    private var sortableColumnsLeft: some TableColumnContent<TrackRow, KeyPathComparator<TrackRow>> {
        TableColumn("#", value: \TrackRow.trackNumber) { (row: TrackRow) in
            self.trackNumberCell(row)
        }
        .width(min: 28, ideal: 32, max: 40)
        .customizationID("trackNumber")

        TableColumn("Title", value: \TrackRow.title, comparator: .localizedStandard) { (row: TrackRow) in
            self.titleCell(row)
        }
        .width(min: 140, ideal: 220)
        .customizationID("title")

        TableColumn("Artist", value: \TrackRow.artistName, comparator: .localizedStandard) { (row: TrackRow) in
            self.artistCell(row)
        }
        .width(min: 100, ideal: 160)
        .customizationID("artist")

        TableColumn("Album", value: \TrackRow.albumName, comparator: .localizedStandard) { (row: TrackRow) in
            self.albumCell(row)
        }
        .width(min: 100, ideal: 160)
        .customizationID("album")

        TableColumn("Year", value: \TrackRow.yearText, comparator: .localizedStandard) { (row: TrackRow) in
            self.yearCell(row)
        }
        .width(min: 48, ideal: 72, max: 120)
        .customizationID("year")

        TableColumn("Genre", value: \TrackRow.genre, comparator: .localizedStandard) { (row: TrackRow) in
            self.genreCell(row)
        }
        .width(min: 80, ideal: 120)
        .customizationID("genre")

        TableColumn("Length", value: \TrackRow.duration) { (row: TrackRow) in
            self.timeCell(row)
        }
        .width(min: 48, ideal: 60, max: 72)
        .customizationID("duration")
    }

    @TableColumnBuilder<TrackRow, KeyPathComparator<TrackRow>>
    private var sortableColumnsRight: some TableColumnContent<TrackRow, KeyPathComparator<TrackRow>> {
        TableColumn("Plays", value: \TrackRow.playCount) { (row: TrackRow) in
            self.playsCell(row)
        }
        .width(min: 36, ideal: 48, max: 56)
        .customizationID("playCount")

        TableColumn("Rating", value: \TrackRow.rating) { (row: TrackRow) in
            self.ratingCell(row)
        }
        .width(min: 52, ideal: 64, max: 72)
        .customizationID("rating")

        TableColumn("Date Added", value: \TrackRow.addedAt) { (row: TrackRow) in
            self.dateAddedCell(row)
        }
        .width(min: 72, ideal: 88)
        .customizationID("addedAt")

        TableColumn("Codec", value: \TrackRow.fileFormat, comparator: .localizedStandard) { (row: TrackRow) in
            self.fileFormatCell(row)
        }
        .width(min: 40, ideal: 52, max: 64)
        .customizationID("fileFormat")

        TableColumn("Bitrate", value: \TrackRow.bitrate) { (row: TrackRow) in
            self.bitrateCell(row)
        }
        .width(min: 64, ideal: 80, max: 96)
        .customizationID("bitrate")

        TableColumn("Sample Rate", value: \TrackRow.sampleRate) { (row: TrackRow) in
            self.sampleRateCell(row)
        }
        .width(min: 64, ideal: 80, max: 96)
        .customizationID("sampleRate")
        .defaultVisibility(.hidden)

        TableColumn("Shuffle Exclude", value: \TrackRow.shuffleSortKey) { (row: TrackRow) in
            self.shuffleExcludedCell(row)
        }
        .width(min: 48, ideal: 56, max: 64)
        .customizationID("excludedFromShuffle")
        .defaultVisibility(.hidden)
    }

    // MARK: Plain (non-sortable) columns

    @TableColumnBuilder<TrackRow, Never>
    private var plainColumnsLeft: some TableColumnContent<TrackRow, Never> {
        TableColumn("#") { (row: TrackRow) in self.trackNumberCell(row) }
            .width(min: 28, ideal: 32, max: 40)
            .customizationID("trackNumber")

        TableColumn("Title") { (row: TrackRow) in self.titleCell(row) }
            .width(min: 140, ideal: 220)
            .customizationID("title")

        TableColumn("Artist") { (row: TrackRow) in self.artistCell(row) }
            .width(min: 100, ideal: 160)
            .customizationID("artist")

        TableColumn("Album") { (row: TrackRow) in self.albumCell(row) }
            .width(min: 100, ideal: 160)
            .customizationID("album")

        TableColumn("Year") { (row: TrackRow) in self.yearCell(row) }
            .width(min: 48, ideal: 72, max: 120)
            .customizationID("year")

        TableColumn("Genre") { (row: TrackRow) in self.genreCell(row) }
            .width(min: 80, ideal: 120)
            .customizationID("genre")

        TableColumn("Length") { (row: TrackRow) in self.timeCell(row) }
            .width(min: 48, ideal: 60, max: 72)
            .customizationID("duration")
    }

    @TableColumnBuilder<TrackRow, Never>
    private var plainColumnsRight: some TableColumnContent<TrackRow, Never> {
        TableColumn("Plays") { (row: TrackRow) in self.playsCell(row) }
            .width(min: 36, ideal: 48, max: 56)
            .customizationID("playCount")

        TableColumn("Rating") { (row: TrackRow) in self.ratingCell(row) }
            .width(min: 52, ideal: 64, max: 72)
            .customizationID("rating")

        TableColumn("Date Added") { (row: TrackRow) in self.dateAddedCell(row) }
            .width(min: 72, ideal: 88)
            .customizationID("addedAt")

        TableColumn("Codec") { (row: TrackRow) in self.fileFormatCell(row) }
            .width(min: 40, ideal: 52, max: 64)
            .customizationID("fileFormat")

        TableColumn("Bitrate") { (row: TrackRow) in self.bitrateCell(row) }
            .width(min: 64, ideal: 80, max: 96)
            .customizationID("bitrate")

        TableColumn("Sample Rate") { (row: TrackRow) in self.sampleRateCell(row) }
            .width(min: 64, ideal: 80, max: 96)
            .customizationID("sampleRate")
            .defaultVisibility(.hidden)

        TableColumn("Shuffle Exclude") { (row: TrackRow) in self.shuffleExcludedCell(row) }
            .width(min: 48, ideal: 56, max: 64)
            .customizationID("excludedFromShuffle")
            .defaultVisibility(.hidden)
    }
}
