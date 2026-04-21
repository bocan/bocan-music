import SwiftUI

// MARK: - PlaylistHeader

/// The header shown above the track list on `PlaylistDetailView`.
public struct PlaylistHeader: View {
    public let title: String
    public let trackCount: Int
    public let duration: TimeInterval
    public let accent: Color?
    public let playAction: () -> Void
    public let shuffleAction: () -> Void

    public init(
        title: String,
        trackCount: Int,
        duration: TimeInterval,
        accent: Color? = nil,
        playAction: @escaping () -> Void,
        shuffleAction: @escaping () -> Void
    ) {
        self.title = title
        self.trackCount = trackCount
        self.duration = duration
        self.accent = accent
        self.playAction = playAction
        self.shuffleAction = shuffleAction
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .fill(self.accent ?? Color.bgTertiary)
                .overlay(
                    Image(systemName: "music.note.list")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                )
                .frame(width: 72, height: 72)

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
                .accessibilityIdentifier(A11y.PlaylistDetail.playButton)

                Button(action: self.shuffleAction) {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(self.trackCount == 0)
                .accessibilityIdentifier(A11y.PlaylistDetail.shuffleButton)
            }
        }
        .padding(20)
        .background(Color.bgPrimary)
        .accessibilityIdentifier(A11y.PlaylistDetail.header)
    }

    private var subtitle: String {
        let countText = self.trackCount == 1 ? "1 song" : "\(self.trackCount) songs"
        let durationText = Self.formatTotal(self.duration)
        return "\(countText) · \(durationText)"
    }

    private static func formatTotal(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) hr \(m) min" }
        return "\(m) min"
    }
}
