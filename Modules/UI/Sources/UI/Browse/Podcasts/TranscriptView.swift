import SwiftUI

// MARK: - TranscriptView

/// A sheet that shows an episode transcript: timed cues or a plain block. It is a
/// pure renderer; loading + parsing is supplied as an async closure so it works
/// from both the episode list and Now Playing, and is testable with a stub.
struct TranscriptView: View {
    let title: String
    let load: () async -> TranscriptContent?

    @Environment(\.dismiss) private var dismiss
    @State private var content: TranscriptContent?
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localized: "Transcript")
                    .font(.headline)
                Spacer()
                // A visible Done button is the macOS convention for dismissing a
                // read-only sheet; `.cancelAction` maps it to Escape so the existing
                // shortcut is also discoverable (and announced by VoiceOver).
                Button(L10n.string("Done")) { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top])
            if !self.title.isEmpty {
                Text(verbatim: self.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal)
            }
            Divider().padding(.top, 8)
            self.contentView
        }
        .task {
            guard !self.didLoad else { return }
            self.content = await self.load()
            self.didLoad = true
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let content {
            switch content {
            case let .timed(cues):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(cues) { cue in
                            self.cueRow(cue)
                        }
                    }
                    .padding()
                }

            case let .plain(text):
                ScrollView {
                    Text(verbatim: text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        } else if !self.didLoad {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                L10n.string("No transcript available for this episode."),
                systemImage: "captions.bubble"
            )
        }
    }

    private func cueRow(_ cue: TranscriptCue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let speaker = cue.speaker, !speaker.isEmpty {
                    Text(verbatim: speaker)
                        .font(.caption.bold())
                }
                Text(verbatim: Self.timestamp(cue.start))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: cue.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Formats a cue start time as `M:SS` or `H:MM:SS`.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
