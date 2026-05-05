import SwiftUI

// MARK: - MenuBarExtraScene

/// Content for the optional menu-bar extra popover.
///
/// Shows artwork, title/artist, and basic transport controls.
/// The icon in the menu bar reflects playback state.
///
/// Wire up in `BocanApp`:
/// ```swift
/// if showMenuBarExtra {
///     MenuBarExtra("Bòcan", systemImage: "music.note") {
///         MenuBarExtraScene(vm: nowPlayingVM)
///     }
///     .menuBarExtraStyle(.window)
/// }
/// ```
public struct MenuBarExtraScene: View {
    public var vm: NowPlayingViewModel
    @Environment(\.openWindow) private var openWindow

    public init(vm: NowPlayingViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Artwork
            Group {
                if let img = self.vm.artwork {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    GradientPlaceholder(seed: 3)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)

            // Track info
            VStack(spacing: 3) {
                Text(self.vm.title.isEmpty ? "Not playing" : self.vm.title)
                    .font(.headline)
                    .lineLimit(1)

                if !self.vm.artist.isEmpty {
                    Text(self.vm.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            // Scrubber
            if self.vm.duration > 0 {
                Slider(
                    value: Binding(
                        get: { self.vm.position / self.vm.duration },
                        set: { fraction in
                            Task { await self.vm.scrub(to: fraction * self.vm.duration) }
                        }
                    ),
                    in: 0 ... 1
                )
                .controlSize(.small)
                .accessibilityLabel("Playback position")
            }

            // Transport
            HStack(spacing: 24) {
                Button {
                    Task { await self.vm.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Within first 3 seconds: previous track · After 3 seconds: restart current track")
                .accessibilityLabel("Previous or restart")

                Button {
                    Task { await self.vm.playPause() }
                } label: {
                    Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(self.vm.isPlaying ? "Pause" : "Play")

                Button {
                    Task { await self.vm.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next")
            }

            Divider()

            Button("Show Bòcan") {
                self.openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.footnote)
        }
        .padding(16)
        .frame(width: 200)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bòcan mini controls")
    }
}
