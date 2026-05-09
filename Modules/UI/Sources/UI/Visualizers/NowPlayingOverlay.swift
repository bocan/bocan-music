import SwiftUI

// MARK: - NowPlayingOverlay

/// Translucent overlay showing the currently playing track's title, artist, and album.
///
/// Fades out automatically after `fadeAfter` seconds and reshows whenever
/// `refreshTrigger` changes (mouse movement) or the track title changes.
struct NowPlayingOverlay: View {
    let title: String
    let artist: String
    let album: String
    var fadeAfter: TimeInterval = 3
    /// Increment this from the parent to force the overlay to reappear and restart the timer.
    var refreshTrigger = 0

    @State private var isVisible = true
    @State private var fadeTask: Task<Void, Never>?

    var body: some View {
        if !self.title.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !self.artist.isEmpty {
                    Text(self.artist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                if !self.album.isEmpty {
                    Text(self.album)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
            .opacity(self.isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.5), value: self.isVisible)
            .onAppear { self.scheduleHide() }
            .onChange(of: self.title) { _, _ in self.reshowAndSchedule() }
            .onChange(of: self.refreshTrigger) { _, _ in self.reshowAndSchedule() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(self.accessibilityDescription)
        }
    }

    private var accessibilityDescription: String {
        var parts = [self.title]
        if !self.artist.isEmpty { parts.append(self.artist) }
        if !self.album.isEmpty { parts.append(self.album) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Fade timer

    private func scheduleHide() {
        self.fadeTask?.cancel()
        self.fadeTask = Task {
            try? await Task.sleep(for: .seconds(self.fadeAfter))
            guard !Task.isCancelled else { return }
            self.isVisible = false
        }
    }

    private func reshowAndSchedule() {
        self.isVisible = true
        self.scheduleHide()
    }
}
