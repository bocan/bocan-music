import Persistence
import SwiftUI

/// Completion threshold: seconds from the end of an episode at which it
/// is considered fully played. Must match PodcastPlayback.completionTailSeconds
/// in the Podcasts module. Update both if changing.
private let completionTailSeconds: TimeInterval = 15

// MARK: - EpisodeStatus

enum EpisodeStatus {
    case unplayed
    case inProgress(Double) // fraction 0.02...0.99
    case played
}

// MARK: - Status derivation

func status(_ item: EpisodeListItem) -> EpisodeStatus {
    guard let state = item.state else { return .unplayed }
    switch state.playState {
    case .unplayed:
        return .unplayed

    case .played:
        return .played

    case .inProgress:
        guard let duration = item.episode.duration, duration > 0 else {
            return .inProgress(0.5)
        }
        let fraction = state.playPosition / duration
        return .inProgress(min(0.99, max(0.02, fraction)))
    }
}

// MARK: - Duration label

private let durationFormatter: DateComponentsFormatter = {
    let f = DateComponentsFormatter()
    f.allowedUnits = [.hour, .minute, .second]
    f.unitsStyle = .abbreviated
    return f
}()

/// Full duration for unplayed/played; time remaining for inProgress.
func durationLabel(_ item: EpisodeListItem) -> String {
    switch status(item) {
    case .unplayed, .played:
        guard let duration = item.episode.duration, duration > 0 else { return "" }
        return durationFormatter.string(from: duration) ?? ""

    case .inProgress:
        guard let duration = item.episode.duration, duration > 0 else { return "" }
        let remaining = max(0, duration - (item.state?.playPosition ?? 0))
        let formatted = durationFormatter.string(from: remaining) ?? ""
        return L10n.string("\(formatted) left")
    }
}

// MARK: - Status label

/// Combined human-readable status (play state, plus download state when present)
/// for the hover tooltip and the VoiceOver label. The icons carry no text on
/// their own, so this is the only place their meaning is spelled out.
func statusLabel(_ item: EpisodeListItem) -> String {
    let play: String
    switch status(item) {
    case .unplayed:
        play = L10n.string("Unplayed")

    case .inProgress:
        let remaining = durationLabel(item) // "Xm left", already localized
        play = remaining.isEmpty ? L10n.string("In progress") : remaining

    case .played:
        play = L10n.string("Played")
    }

    let download: String? = switch item.state?.downloadState ?? .none {
    case .downloaded:
        L10n.string("Downloaded")

    case .downloading:
        L10n.string("Downloading")

    case .queued:
        L10n.string("Download queued")

    case .none, .failed:
        nil
    }

    guard let download else { return play }
    return L10n.string("\(play) · \(download)")
}

// MARK: - ProgressRing

struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: self.fraction)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - EpisodeStatusIndicator

struct EpisodeStatusIndicator: View {
    let item: EpisodeListItem

    var body: some View {
        self.playIndicator
            .overlay(alignment: .bottomTrailing) { self.downloadBadge }
            .help(statusLabel(self.item))
            .accessibilityLabel(statusLabel(self.item))
    }

    @ViewBuilder
    private var playIndicator: some View {
        switch status(self.item) {
        case .unplayed:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)

        case let .inProgress(fraction):
            ProgressRing(fraction: fraction)
                .frame(width: 14, height: 14)

        case .played:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Small corner badge: filled when the episode is downloaded for offline play,
    /// hollow while a download is queued or running.
    @ViewBuilder
    private var downloadBadge: some View {
        switch self.item.state?.downloadState ?? .none {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.accentColor)
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .offset(x: 3, y: 3)

        case .queued, .downloading:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .offset(x: 3, y: 3)

        case .none, .failed:
            EmptyView()
        }
    }
}
