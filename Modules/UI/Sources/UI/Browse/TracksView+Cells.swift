import AppKit
import Persistence
import SwiftUI

// MARK: - TracksView cell builders

extension TracksView {
    func trackNumberCell(_ row: TrackRow) -> some View {
        Text(row.track.trackNumber.map { "\($0)" } ?? "")
            .font(Typography.footnote)
            .foregroundStyle(Color.textSecondary)
            .monospacedDigit()
    }

    func titleCell(_ row: TrackRow) -> some View {
        Text(row.track.title ?? "Unknown")
            .font(Typography.body)
            .foregroundStyle(row.track.loved ? Color.lovedTint : Color.textPrimary)
            .lineLimit(1)
            .onDrag {
                // Drag the full selection when the row is part of it;
                // otherwise just this single row.
                let dragIDs: [Int64] = if let rowID = row.id, self.vm.selection.contains(rowID) {
                    self.vm.selection.compactMap(\.self)
                } else {
                    [row.id].compactMap(\.self)
                }
                let payload = dragIDs.map { "\($0)" }.joined(separator: ",")
                return NSItemProvider(object: payload as NSString)
            }
    }

    func artistCell(_ row: TrackRow) -> some View {
        Text(row.artistName)
            .font(Typography.body)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
    }

    func albumCell(_ row: TrackRow) -> some View {
        Text(row.albumName)
            .font(Typography.body)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
    }

    func yearCell(_ row: TrackRow) -> some View {
        Text(verbatim: row.yearText)
            .font(Typography.footnote)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
    }

    func genreCell(_ row: TrackRow) -> some View {
        Text(row.genre)
            .font(Typography.body)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
    }

    func timeCell(_ row: TrackRow) -> some View {
        Text(Formatters.duration(row.duration))
            .font(Typography.footnote)
            .foregroundStyle(Color.textSecondary)
            .monospacedDigit()
    }

    func playsCell(_ row: TrackRow) -> some View {
        Text("\(row.playCount)")
            .font(Typography.footnote)
            .foregroundStyle(Color.textSecondary)
            .monospacedDigit()
    }

    @ViewBuilder func ratingCell(_ row: TrackRow) -> some View {
        let stars = Formatters.stars(from: row.rating)
        Text(stars > 0 ? String(repeating: "★", count: stars) : "")
            .font(Typography.footnote)
            .foregroundStyle(Color.ratingFill)
    }

    func dateAddedCell(_ row: TrackRow) -> some View {
        Text(Formatters.shortDate(epochSeconds: row.addedAt))
            .font(Typography.footnote)
            .foregroundStyle(Color.textSecondary)
    }

    func fileFormatCell(_ row: TrackRow) -> some View {
        Text(row.fileFormat)
            .font(Typography.footnote)
            .foregroundStyle(Color.textSecondary)
    }

    func bitrateCell(_ row: TrackRow) -> some View {
        Text(row.bitrate > 0 ? "\(row.bitrate) kbps" : "")
            .font(Typography.footnote)
            .foregroundStyle(Color.textSecondary)
            .monospacedDigit()
    }

    func sampleRateCell(_ row: TrackRow) -> some View {
        Text(Self.formatSampleRate(row.sampleRate))
            .font(Typography.footnote)
            .foregroundStyle(Color.textSecondary)
            .monospacedDigit()
    }

    private static func formatSampleRate(_ hz: Int) -> String {
        guard hz > 0 else { return "" }
        let khz = Double(hz) / 1000.0
        if khz == khz.rounded() {
            return String(format: "%.0f kHz", khz)
        }
        return String(format: "%.1f kHz", khz)
    }

    func shuffleExcludedCell(_ row: TrackRow) -> some View {
        Toggle("", isOn: Binding(
            get: { row.excludedFromShuffle },
            set: { excluded in
                if let id = row.id {
                    Task { await self.library.setTrackExcludedFromShuffle(trackID: id, excluded: excluded) }
                }
            }
        ))
        .labelsHidden()
        .toggleStyle(.checkbox)
    }
}
