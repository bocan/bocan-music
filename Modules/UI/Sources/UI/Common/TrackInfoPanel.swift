import Persistence
import SwiftUI

// MARK: - TrackInfoPanel

/// Lightweight read-only metadata panel for the currently-playing track.
///
/// Opens as an independent floating window from the mini-player info button,
/// so users can see track details without leaving mini mode.
public struct TrackInfoPanel: View {
    @EnvironmentObject private var library: LibraryViewModel

    /// Creates a `TrackInfoPanel`.
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider()
            self.metadataForm
        }
        .frame(width: 320)
        .background(.background)
        .navigationTitle(
            self.library.nowPlaying.title.isEmpty ? "Track Info" : self.library.nowPlaying.title
        )
    }

    // MARK: - Sub-views

    private var header: some View {
        let np = self.library.nowPlaying
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if let img = np.artwork {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    GradientPlaceholder(seed: 2)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(np.title.isEmpty ? "Not Playing" : np.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if !np.artist.isEmpty {
                    Text(np.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !np.album.isEmpty {
                    Text(np.album)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    // MARK: - Form

    private var metadataForm: some View {
        let np = self.library.nowPlaying
        let track = np.currentTrack
        return Form {
            if let track {
                let hasTags = track.year != nil
                    || !(track.genre ?? "").isEmpty
                    || !(track.composer ?? "").isEmpty
                    || track.trackNumber != nil
                    || track.discNumber != nil
                if hasTags {
                    Section("Tags") {
                        if let year = track.year {
                            LabeledContent("Year") { Text(verbatim: "\(year)") }
                        }
                        if let genre = track.genre, !genre.isEmpty {
                            LabeledContent("Genre") { Text(genre) }
                        }
                        if let composer = track.composer, !composer.isEmpty {
                            LabeledContent("Composer") { Text(composer) }
                        }
                        if track.trackNumber != nil || track.trackTotal != nil {
                            LabeledContent("Track") {
                                Text(Self.formatNumber(track.trackNumber, of: track.trackTotal))
                            }
                        }
                        if track.discNumber != nil || track.discTotal != nil {
                            LabeledContent("Disc") {
                                Text(Self.formatNumber(track.discNumber, of: track.discTotal))
                            }
                        }
                    }
                }
                Section("Audio") {
                    LabeledContent("Format") { Text(track.fileFormat.uppercased()) }
                    LabeledContent("Duration") { Text(Self.formatDuration(np.duration)) }
                    if let bitDepth = track.bitDepth {
                        LabeledContent("Bit Depth") { Text("\(bitDepth)-bit") }
                    }
                    LabeledContent("Sample Rate") { Text(Self.formatSampleRate(track.sampleRate)) }
                    if let bitrate = track.bitrate {
                        LabeledContent("Bitrate") { Text("\(bitrate) kbps") }
                    }
                    if let channels = track.channelCount {
                        LabeledContent("Channels") { Text(Self.formatChannels(channels)) }
                    }
                }
                Section("File") {
                    LabeledContent("Size") { Text(Self.formatFileSize(track.fileSize)) }
                    LabeledContent("Location") {
                        Text(track.filePathDisplay ?? track.fileURL)
                            .textSelection(.enabled)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .help(track.fileURL)
                }
            } else {
                Section("Audio") {
                    LabeledContent("Duration") { Text(Self.formatDuration(np.duration)) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Formatters

    private static func formatNumber(_ number: Int?, of total: Int?) -> String {
        switch (number, total) {
        case let (n?, t?):
            "\(n) of \(t)"

        case let (n?, nil):
            "\(n)"

        default:
            "—"
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let s = Int(seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func formatSampleRate(_ hz: Int?) -> String {
        guard let hz else { return "—" }
        let khz = Double(hz) / 1000.0
        if khz == khz.rounded() { return "\(Int(khz)) kHz" }
        return String(format: "%.1f kHz", khz)
    }

    private static func formatChannels(_ count: Int) -> String {
        switch count {
        case 1:
            "1 (Mono)"

        case 2:
            "2 (Stereo)"

        default:
            "\(count)"
        }
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
