import SwiftUI

// MARK: - MiniPlayerView

/// Root view for the Mini Player window.  Adapts its layout to the window size:
/// - Square (≥ 220 × 220): `MiniPlayerSquare`
/// - Compact horizontal (width ≥ 200): `MiniPlayerCompact`
/// - Minimal strip: title + play/pause only
public struct MiniPlayerView: View {
    @ObservedObject public var vm: MiniPlayerViewModel
    @Environment(\.openWindow) private var openWindow

    public init(vm: MiniPlayerViewModel) {
        self.vm = vm
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                self.adaptiveLayout(size: geo.size)

                // Always-on-top pin button
                self.pinButton
                    .padding(6)
            }
        }
        .background(.ultraThinMaterial)
        .onAppear { self.applyWindowLevel() }
        .onChange(of: self.vm.alwaysOnTop) { _ in self.applyWindowLevel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini Player")
    }

    // MARK: - Layout selection

    @ViewBuilder
    private func adaptiveLayout(size: CGSize) -> some View {
        if size.width >= 220, size.height >= 220 {
            MiniPlayerSquare(vm: self.vm)
                .transition(.opacity.animation(.spring(duration: 0.2)))
        } else if size.width >= 200 {
            MiniPlayerCompact(vm: self.vm)
                .transition(.opacity.animation(.spring(duration: 0.2)))
        } else {
            // Minimal strip
            HStack(spacing: 10) {
                Text(self.vm.nowPlaying.title.isEmpty ? "Not playing" : self.vm.nowPlaying.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                Button {
                    Task { await self.vm.nowPlaying.playPause() }
                } label: {
                    Image(systemName: self.vm.nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.textPrimary)
                .accessibilityLabel(self.vm.nowPlaying.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 12)
            .transition(.opacity.animation(.spring(duration: 0.2)))
        }
    }

    // MARK: - Pin button

    private var pinButton: some View {
        Button {
            self.vm.alwaysOnTop.toggle()
        } label: {
            Image(systemName: self.vm.alwaysOnTop ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(self.vm.alwaysOnTop ? Color.accentColor : Color.textTertiary)
        }
        .buttonStyle(.plain)
        .help(self.vm.alwaysOnTop ? "Unpin — stop floating above other windows" : "Pin — float above other windows")
        .accessibilityLabel(self.vm.alwaysOnTop ? "Unpin mini player" : "Pin mini player above other windows")
    }

    // MARK: - Window level

    private func applyWindowLevel() {
        // Find the mini player window by its scene title and adjust its level.
        guard let window = NSApp.windows.first(where: { $0.title == "Mini Player" || $0.identifier?.rawValue == "mini" }) else { return }
        window.level = self.vm.alwaysOnTop ? .floating : .normal
    }
}
