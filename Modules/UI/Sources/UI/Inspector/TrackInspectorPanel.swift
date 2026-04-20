import AppKit
import Foundation
import Persistence
import SwiftUI

// MARK: - TrackInspectorPanel

/// A non-modal inspector window that shows read-only metadata for the
/// selected track(s).
///
/// Opened via `⌘I` or via the "Get Info" context-menu item.
/// Uses SwiftUI `TabView` with three tabs: Details, File, History.
public struct TrackInspectorPanel: View {
    let track: Track
    let database: Database

    @State private var coverArtPath: String?
    @State private var artistName: String?
    @State private var albumName: String?

    public init(track: Track, database: Database) {
        self.track = track
        self.database = database
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header — cover art, title, artist — all centred.  The art
            // fills the available width (up to a maximum so it doesn't
            // swallow the whole window on a tall resize) and uses its own
            // 1:1 aspect ratio for the height.
            VStack(spacing: 10) {
                Artwork(
                    artPath: self.coverArtPath,
                    seed: Int(self.track.id ?? 0),
                    size: 320
                )
                .frame(maxWidth: 360, maxHeight: 360)

                Text(self.track.title ?? "—")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .textSelection(.enabled)

                if let artist = artistName, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Small gap before the tab strip / data.
            Spacer().frame(height: 12)

            TabView {
                DetailsTab(track: self.track, albumName: self.albumName)
                    .tabItem { Label("Details", systemImage: "music.note") }

                FileTab(track: self.track)
                    .tabItem { Label("File", systemImage: "doc") }

                HistoryTab(track: self.track)
                    .tabItem { Label("History", systemImage: "clock") }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 560, idealHeight: 600)
        .task(id: self.track.id) {
            await self.load()
        }
    }

    private func load() async {
        self.coverArtPath = nil
        self.artistName = nil
        self.albumName = nil

        if let hash = track.coverArtHash {
            let repo = CoverArtRepository(database: self.database)
            if let art = try? await repo.fetch(hash: hash) {
                self.coverArtPath = art.path
            }
        }

        if let artistID = track.artistID {
            let repo = ArtistRepository(database: self.database)
            if let artist = try? await repo.fetch(id: artistID) {
                self.artistName = artist.name
            }
        }

        if let albumID = track.albumID {
            let repo = AlbumRepository(database: self.database)
            if let album = try? await repo.fetch(id: albumID) {
                self.albumName = album.title
            }
        }
    }
}

// MARK: - Details tab

private struct DetailsTab: View {
    let track: Track
    let albumName: String?

    var body: some View {
        Form {
            InspectorRow("Title", value: self.track.title)
            InspectorRow("Album", value: self.albumName)
            InspectorRow("Year", value: self.yearDisplay)
            InspectorRow("Genre", value: self.track.genre)
            InspectorRow("Composer", value: self.track.composer)
            InspectorRow("Track #", value: self.trackNumberString)
            InspectorRow("Disc #", value: self.discNumberString)
            InspectorRow("BPM", value: self.track.bpm.map { String(format: "%.0f", $0) })
            InspectorRow("Rating", value: self.ratingString)
            InspectorRow("Loved", value: self.track.loved ? "Yes" : "No")
        }
        .formStyle(.columns)
        .padding(12)
    }

    // MARK: Computed display values

    private var yearDisplay: String? {
        if let text = track.yearText, !text.isEmpty { return text }
        return self.track.year.map(String.init)
    }

    private var trackNumberString: String? {
        guard let n = track.trackNumber else { return nil }
        if let total = track.trackTotal { return "\(n) of \(total)" }
        return "\(n)"
    }

    private var discNumberString: String? {
        guard let n = track.discNumber else { return nil }
        if let total = track.discTotal { return "\(n) of \(total)" }
        return "\(n)"
    }

    private var ratingString: String? {
        guard self.track.rating > 0 else { return "None" }
        let stars = Int((Double(track.rating) / 100.0 * 5.0).rounded())
        return String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
    }
}

// MARK: - File tab

private struct FileTab: View {
    let track: Track

    var body: some View {
        Form {
            InspectorRow("Path", value: self.track.filePathDisplay ?? self.track.fileURL, wrap: true)
            Section {
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        guard let url = URL(string: track.fileURL) else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Spacer()
                }
            }
            InspectorRow("Format", value: self.track.fileFormat.uppercased())
            InspectorRow("Sample Rate", value: self.track.sampleRate.map { "\($0 / 1000) kHz" })
            InspectorRow("Bit Depth", value: self.track.bitDepth.map { "\($0)-bit" })
            InspectorRow("Bitrate", value: self.track.bitrate.map { "\($0) kbps" })
            InspectorRow("File Size", value: self.formattedFileSize)
            InspectorRow("Duration", value: self.formattedDuration)
            InspectorRow("Lossless", value: self.track.isLossless.map { $0 ? "Yes" : "No" })
        }
        .formStyle(.columns)
        .padding(12)
    }

    private var formattedFileSize: String? {
        guard self.track.fileSize > 0 else { return nil }
        let mb = Double(track.fileSize) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }

    private var formattedDuration: String? {
        guard self.track.duration > 0 else { return nil }
        let total = Int(track.duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - History tab

private struct HistoryTab: View {
    let track: Track

    var body: some View {
        Form {
            InspectorRow("Date Added", value: self.formattedDate(self.track.addedAt))
            InspectorRow("Date Modified", value: self.formattedDate(self.track.updatedAt))
            InspectorRow("Play Count", value: "\(self.track.playCount)")
            InspectorRow("Skip Count", value: "\(self.track.skipCount)")
            InspectorRow("Last Played", value: self.track.lastPlayedAt.flatMap { self.formattedDate($0) })
        }
        .formStyle(.columns)
        .padding(12)
    }

    private func formattedDate(_ epoch: Int64?) -> String? {
        guard let epoch else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - InspectorRow

private struct InspectorRow: View {
    let label: String
    let value: String?
    var wrap = false

    init(_ label: String, value: String?, wrap: Bool = false) {
        self.label = label
        self.value = value
        self.wrap = wrap
    }

    var body: some View {
        LabeledContent(self.label) {
            if let value {
                Text(value)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(self.wrap ? nil : 1)
                    .truncationMode(.middle)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
