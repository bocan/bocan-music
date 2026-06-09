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
    /// Holds the slider fraction while the user is dragging; seeking is deferred
    /// to drag-end so the engine isn't bombarded with a seek per mouse-move event.
    @State private var scrubDragFraction: Double?

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
                MarqueeText(
                    self.vm.title.isEmpty ? L10n.string("Not playing") : self.vm.title,
                    font: .headline,
                    foregroundStyle: Color.primary
                )

                if !self.vm.artist.isEmpty {
                    MarqueeText(
                        self.vm.artist,
                        font: .subheadline,
                        foregroundStyle: Color.secondary
                    )
                }
            }
            .frame(maxWidth: .infinity)

            // Scrubber
            if self.vm.duration > 0 {
                Slider(
                    value: Binding(
                        get: { self.scrubDragFraction ?? (self.vm.position / self.vm.duration) },
                        set: { self.scrubDragFraction = $0 }
                    ),
                    in: 0 ... 1
                ) { editing in
                    if !editing, let fraction = self.scrubDragFraction {
                        self.scrubDragFraction = nil
                        Task { await self.vm.scrub(to: fraction * self.vm.duration) }
                    }
                }
                .controlSize(.small)
                .accessibilityLabel(L10n.string("Playback position"))
            }

            // Transport
            HStack(spacing: 24) {
                Button {
                    Task { await self.vm.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .scaledSystemFont(size: 16, weight: .semibold)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Within first 3 seconds: previous track · After 3 seconds: restart current track"))
                .accessibilityLabel(L10n.string("Previous or restart"))

                Button {
                    Task { await self.vm.playPause() }
                } label: {
                    Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                        .scaledSystemFont(size: 22, weight: .bold)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(self.vm.isPlaying ? L10n.string("Pause") : L10n.string("Play"))

                Button {
                    Task { await self.vm.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .scaledSystemFont(size: 16, weight: .semibold)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Next"))
            }

            Divider()

            Button(L10n.string("Show Bòcan")) {
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
        .accessibilityLabel(L10n.string("Bòcan mini controls"))
    }
}
