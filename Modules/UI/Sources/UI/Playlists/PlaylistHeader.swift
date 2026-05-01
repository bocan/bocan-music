import AppKit
import SwiftUI

// MARK: - PlaylistHeader

/// The header shown above the track list on `PlaylistDetailView`.
public struct PlaylistHeader: View {
    public let title: String
    public let trackCount: Int
    public let duration: TimeInterval
    public let accent: Color?
    /// User-set cover art image.  Shown in preference to the mosaic.
    public let coverImage: NSImage?
    /// Auto-generated 2×2 mosaic of album covers.  Used when `coverImage` is nil.
    public let mosaicImage: NSImage?
    public let playAction: () -> Void
    public let shuffleAction: () -> Void

    public init(
        title: String,
        trackCount: Int,
        duration: TimeInterval,
        accent: Color? = nil,
        coverImage: NSImage? = nil,
        mosaicImage: NSImage? = nil,
        playAction: @escaping () -> Void,
        shuffleAction: @escaping () -> Void
    ) {
        self.title = title
        self.trackCount = trackCount
        self.duration = duration
        self.accent = accent
        self.coverImage = coverImage
        self.mosaicImage = mosaicImage
        self.playAction = playAction
        self.shuffleAction = shuffleAction
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            self.coverThumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(self.title)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Text(self.subtitle)
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: self.playAction) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(self.trackCount == 0)
                .help("Play this playlist in order")
                .accessibilityLabel("Play")
                .accessibilityHint("Starts playback from the first track in this playlist")
                .accessibilityIdentifier(A11y.PlaylistDetail.playButton)

                Button(action: self.shuffleAction) {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(self.trackCount == 0)
                .help("Shuffle and play this playlist")
                .accessibilityLabel("Shuffle")
                .accessibilityHint("Starts playback in shuffled order")
                .accessibilityIdentifier(A11y.PlaylistDetail.shuffleButton)
            }
        }
        .padding(20)
        .background(Color.bgPrimary)
        .accessibilityIdentifier(A11y.PlaylistDetail.header)
    }

    // MARK: - Cover thumbnail

    /// 72×72 pt square showing (in priority order):
    /// 1. User-set cover art
    /// 2. Auto-generated album mosaic
    /// 3. Solid accent-colour rectangle with a music.note.list icon
    @ViewBuilder
    private var coverThumbnail: some View {
        let effective = self.coverImage ?? self.mosaicImage
        Group {
            if let img = effective {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                self.accentPlaceholder
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        .accessibilityHidden(true)
    }

    private var accentPlaceholder: some View {
        RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
            .fill(self.accent ?? Color.bgTertiary)
            .overlay(
                Image(systemName: "music.note.list")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
            )
    }

    private var subtitle: String {
        let countText = self.trackCount == 1 ? "1 song" : "\(self.trackCount) songs"
        let durationText = Self.formatTotal(self.duration)
        return "\(countText) · \(durationText)"
    }

    private static func formatTotal(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(minutes) min"
    }
}
