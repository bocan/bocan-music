import AppKit
import Library

// MARK: - Column identifiers

extension NSUserInterfaceItemIdentifier {
    static let databaseID = NSUserInterfaceItemIdentifier("col.databaseID")
    static let trackNumber = NSUserInterfaceItemIdentifier("col.trackNumber")
    static let trackTotal = NSUserInterfaceItemIdentifier("col.trackTotal")
    static let discNumber = NSUserInterfaceItemIdentifier("col.discNumber")
    static let discTotal = NSUserInterfaceItemIdentifier("col.discTotal")
    static let title = NSUserInterfaceItemIdentifier("col.title")
    static let artist = NSUserInterfaceItemIdentifier("col.artist")
    static let album = NSUserInterfaceItemIdentifier("col.album")
    static let year = NSUserInterfaceItemIdentifier("col.year")
    static let genre = NSUserInterfaceItemIdentifier("col.genre")
    static let duration = NSUserInterfaceItemIdentifier("col.duration")
    static let playCount = NSUserInterfaceItemIdentifier("col.playCount")
    static let rating = NSUserInterfaceItemIdentifier("col.rating")
    static let addedAt = NSUserInterfaceItemIdentifier("col.addedAt")
    static let fileFormat = NSUserInterfaceItemIdentifier("col.fileFormat")
    static let bitrate = NSUserInterfaceItemIdentifier("col.bitrate")
    static let sampleRate = NSUserInterfaceItemIdentifier("col.sampleRate")
    static let shuffleExclude = NSUserInterfaceItemIdentifier("col.shuffleExclude")
    static let loved = NSUserInterfaceItemIdentifier("col.loved")
    static let composer = NSUserInterfaceItemIdentifier("col.composer")
    static let bpm = NSUserInterfaceItemIdentifier("col.bpm")
    static let key = NSUserInterfaceItemIdentifier("col.key")
    static let bitDepth = NSUserInterfaceItemIdentifier("col.bitDepth")
    static let channelCount = NSUserInterfaceItemIdentifier("col.channelCount")
    static let isLossless = NSUserInterfaceItemIdentifier("col.isLossless")
    static let skipCount = NSUserInterfaceItemIdentifier("col.skipCount")
    static let lastPlayedAt = NSUserInterfaceItemIdentifier("col.lastPlayedAt")
    static let fileSize = NSUserInterfaceItemIdentifier("col.fileSize")
    static let fileMtime = NSUserInterfaceItemIdentifier("col.fileMtime")
}

// MARK: - TrackTable static helpers

extension TrackTable {
    static func addColumns(to tableView: NSTableView, sortable: Bool) {
        let autosaveName = tableView.autosaveName ?? ""
        for spec in columnSpecs {
            let col = NSTableColumn(identifier: spec.id)
            col.title = spec.title
            col.headerCell.title = spec.title
            col.headerCell.setAccessibilityLabel(spec.title)
            col.minWidth = spec.minWidth
            col.width = spec.idealWidth
            col.maxWidth = spec.maxWidth
            col.isHidden = self.savedColumnVisibility(autosaveName: autosaveName, id: spec.id) ?? spec.hidden
            if sortable, let key = spec.sortKey {
                col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
            tableView.addTableColumn(col)
        }
    }

    // MARK: Column visibility persistence

    /// Persists a column's hidden state to UserDefaults so it survives view recreation.
    /// `NSTableView.autosaveTableColumns` only saves width and order, not visibility.
    static func saveColumnVisibility(autosaveName: String, column: NSTableColumn) {
        let key = "bocan.col.hidden.\(autosaveName).\(column.identifier.rawValue)"
        UserDefaults.standard.set(column.isHidden, forKey: key)
    }

    /// Returns the persisted hidden state for a column, or `nil` if not yet saved.
    private static func savedColumnVisibility(
        autosaveName: String,
        id: NSUserInterfaceItemIdentifier
    ) -> Bool? {
        let key = "bocan.col.hidden.\(autosaveName).\(id.rawValue)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func buildHeaderMenu(for tableView: NSTableView, coordinator: TrackTableCoordinator) {
        let menu = NSMenu()
        for col in tableView.tableColumns {
            let item = NSMenuItem(
                title: col.title,
                action: #selector(TrackTableCoordinator.toggleColumnVisibility(_:)),
                keyEquivalent: ""
            )
            item.representedObject = col
            item.state = col.isHidden ? .off : .on
            item.target = coordinator
            menu.addItem(item)
        }
        tableView.headerView?.menu = menu
    }

    // MARK: Sort helpers

    // swiftlint:disable cyclomatic_complexity
    /// Maps a `KeyPathComparator<TrackRow>` to the sort descriptor key string.
    static func sortKey(for comparator: KeyPathComparator<TrackRow>) -> String? {
        let ord = comparator.order
        if comparator == KeyPathComparator(\TrackRow.trackNumber, order: ord) { return "trackNumber" }
        if comparator == KeyPathComparator(\TrackRow.trackTotal, order: ord) { return "trackTotal" }
        if comparator == KeyPathComparator(\TrackRow.discNumber, order: ord) { return "discNumber" }
        if comparator == KeyPathComparator(\TrackRow.discTotal, order: ord) { return "discTotal" }
        if comparator == KeyPathComparator(\TrackRow.databaseID, order: ord) { return "databaseID" }
        if comparator == KeyPathComparator(\TrackRow.title, comparator: .localizedStandard, order: ord) { return "title" }
        if comparator == KeyPathComparator(\TrackRow.artistName, comparator: .localizedStandard, order: ord) { return "artistName" }
        if comparator == KeyPathComparator(\TrackRow.albumName, comparator: .localizedStandard, order: ord) { return "albumName" }
        if comparator == KeyPathComparator(\TrackRow.yearText, comparator: .localizedStandard, order: ord) { return "yearText" }
        if comparator == KeyPathComparator(\TrackRow.genre, comparator: .localizedStandard, order: ord) { return "genre" }
        if comparator == KeyPathComparator(\TrackRow.duration, order: ord) { return "duration" }
        if comparator == KeyPathComparator(\TrackRow.playCount, order: ord) { return "playCount" }
        if comparator == KeyPathComparator(\TrackRow.rating, order: ord) { return "rating" }
        if comparator == KeyPathComparator(\TrackRow.addedAt, order: ord) { return "addedAt" }
        if comparator == KeyPathComparator(\TrackRow.fileFormat, comparator: .localizedStandard, order: ord) { return "fileFormat" }
        if comparator == KeyPathComparator(\TrackRow.bitrate, order: ord) { return "bitrate" }
        if comparator == KeyPathComparator(\TrackRow.sampleRate, order: ord) { return "sampleRate" }
        if comparator == KeyPathComparator(\TrackRow.shuffleSortKey, order: ord) { return "shuffleSortKey" }
        if comparator == KeyPathComparator(\TrackRow.lovedSortKey, order: ord) { return "lovedSortKey" }
        if comparator == KeyPathComparator(\TrackRow.composer, comparator: .localizedStandard, order: ord) { return "composer" }
        if comparator == KeyPathComparator(\TrackRow.bpm, order: ord) { return "bpm" }
        if comparator == KeyPathComparator(\TrackRow.key, comparator: .localizedStandard, order: ord) { return "key" }
        if comparator == KeyPathComparator(\TrackRow.bitDepth, order: ord) { return "bitDepth" }
        if comparator == KeyPathComparator(\TrackRow.channelCount, order: ord) { return "channelCount" }
        if comparator == KeyPathComparator(\TrackRow.isLossless, order: ord) { return "isLossless" }
        if comparator == KeyPathComparator(\TrackRow.skipCount, order: ord) { return "skipCount" }
        if comparator == KeyPathComparator(\TrackRow.lastPlayedAt, order: ord) { return "lastPlayedAt" }
        if comparator == KeyPathComparator(\TrackRow.fileSize, order: ord) { return "fileSize" }
        if comparator == KeyPathComparator(\TrackRow.fileMtime, order: ord) { return "fileMtime" }
        return nil
    }

    // swiftlint:enable cyclomatic_complexity

    // swiftlint:disable function_body_length
    /// Maps a sort descriptor back to a `KeyPathComparator<TrackRow>`.
    static func comparator(from descriptor: NSSortDescriptor) -> KeyPathComparator<TrackRow>? {
        let order: SortOrder = descriptor.ascending ? .forward : .reverse
        switch descriptor.key {
        case "trackNumber":
            return KeyPathComparator(\TrackRow.trackNumber, order: order)

        case "trackTotal":
            return KeyPathComparator(\TrackRow.trackTotal, order: order)

        case "discNumber":
            return KeyPathComparator(\TrackRow.discNumber, order: order)

        case "discTotal":
            return KeyPathComparator(\TrackRow.discTotal, order: order)

        case "databaseID":
            return KeyPathComparator(\TrackRow.databaseID, order: order)

        case "title":
            return KeyPathComparator(\TrackRow.title, comparator: .localizedStandard, order: order)

        case "artistName":
            return KeyPathComparator(\TrackRow.artistName, comparator: .localizedStandard, order: order)

        case "albumName":
            return KeyPathComparator(\TrackRow.albumName, comparator: .localizedStandard, order: order)

        case "yearText":
            return KeyPathComparator(\TrackRow.yearText, comparator: .localizedStandard, order: order)

        case "genre":
            return KeyPathComparator(\TrackRow.genre, comparator: .localizedStandard, order: order)

        case "duration":
            return KeyPathComparator(\TrackRow.duration, order: order)

        case "playCount":
            return KeyPathComparator(\TrackRow.playCount, order: order)

        case "rating":
            return KeyPathComparator(\TrackRow.rating, order: order)

        case "addedAt":
            return KeyPathComparator(\TrackRow.addedAt, order: order)

        case "fileFormat":
            return KeyPathComparator(\TrackRow.fileFormat, comparator: .localizedStandard, order: order)

        case "bitrate":
            return KeyPathComparator(\TrackRow.bitrate, order: order)

        case "sampleRate":
            return KeyPathComparator(\TrackRow.sampleRate, order: order)

        case "shuffleSortKey":
            return KeyPathComparator(\TrackRow.shuffleSortKey, order: order)

        case "lovedSortKey":
            return KeyPathComparator(\TrackRow.lovedSortKey, order: order)

        case "composer":
            return KeyPathComparator(\TrackRow.composer, comparator: .localizedStandard, order: order)

        case "bpm":
            return KeyPathComparator(\TrackRow.bpm, order: order)

        case "key":
            return KeyPathComparator(\TrackRow.key, comparator: .localizedStandard, order: order)

        case "bitDepth":
            return KeyPathComparator(\TrackRow.bitDepth, order: order)

        case "channelCount":
            return KeyPathComparator(\TrackRow.channelCount, order: order)

        case "isLossless":
            return KeyPathComparator(\TrackRow.isLossless, order: order)

        case "skipCount":
            return KeyPathComparator(\TrackRow.skipCount, order: order)

        case "lastPlayedAt":
            return KeyPathComparator(\TrackRow.lastPlayedAt, order: order)

        case "fileSize":
            return KeyPathComparator(\TrackRow.fileSize, order: order)

        case "fileMtime":
            return KeyPathComparator(\TrackRow.fileMtime, order: order)

        default:
            return nil
        }
    }

    // swiftlint:enable function_body_length

    // swiftlint:disable function_body_length
    /// Returns the display string for a column/row combination.
    static func displayValue(for colID: NSUserInterfaceItemIdentifier, row: TrackRow) -> String {
        switch colID {
        case .databaseID:
            return row.databaseID == 0 ? "" : String(row.databaseID)

        case .trackNumber:
            return row.trackNumber == 0 ? "" : String(row.trackNumber)

        case .trackTotal:
            return row.trackTotal == 0 ? "" : String(row.trackTotal)

        case .discNumber:
            return row.discNumber == 0 ? "" : String(row.discNumber)

        case .discTotal:
            return row.discTotal == 0 ? "" : String(row.discTotal)

        case .title:
            return row.title.isEmpty ? "Unknown" : row.title

        case .artist:
            return row.artistName

        case .album:
            return row.albumName

        case .year:
            return row.yearText

        case .genre:
            return row.genre

        case .duration:
            return Formatters.duration(row.duration)

        case .playCount:
            return row.playCount == 0 ? "" : String(row.playCount)

        case .rating:
            let n = Formatters.stars(from: row.rating)
            return n > 0 ? String(repeating: "★", count: n) : ""

        case .addedAt:
            return Formatters.shortDate(epochSeconds: row.addedAt)

        case .fileFormat:
            return row.fileFormat

        case .bitrate:
            return row.bitrate > 0 ? "\(row.bitrate) kbps" : ""

        case .sampleRate:
            return self.formatSampleRate(row.sampleRate)

        case .loved:
            // Rendered by LoveButtonCell; text fallback for accessibility/copy.
            return row.loved ? "♥" : ""

        case .composer:
            return row.composer

        case .bpm:
            return row.bpm > 0 ? String(format: "%.0f", row.bpm) : ""

        case .key:
            return row.key

        case .bitDepth:
            return row.bitDepth > 0 ? "\(row.bitDepth)-bit" : ""

        case .channelCount:
            switch row.channelCount {
            case 0:
                return ""

            case 1:
                return "Mono"

            case 2:
                return "Stereo"

            default:
                return "\(row.channelCount) ch"
            }

        case .isLossless:
            guard row.bitDepth > 0 || !row.fileFormat.isEmpty else { return "" }
            return row.isLossless == 1 ? "✓" : "✗"

        case .skipCount:
            return row.skipCount == 0 ? "" : String(row.skipCount)

        case .lastPlayedAt:
            return Formatters.shortDate(epochSeconds: row.lastPlayedAt)

        case .fileSize:
            return Formatters.fileSize(row.fileSize)

        case .fileMtime:
            return Formatters.shortDate(epochSeconds: row.fileMtime)

        default:
            return ""
        }
    }

    // swiftlint:enable function_body_length

    static func formatSampleRate(_ hz: Int) -> String {
        guard hz > 0 else { return "" }
        let khz = Double(hz) / 1000.0
        return khz == khz.rounded()
            ? String(format: "%.0f kHz", khz)
            : String(format: "%.1f kHz", khz)
    }
}
