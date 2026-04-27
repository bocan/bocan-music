import AppKit
import SwiftUI

// MARK: - MiniPlayerView

/// Root view for the Mini Player window.
///
/// Layout is controlled by `MiniPlayerViewModel.layout` (strip / compact / square)
/// and can be cycled via the layout button in the chrome overlay.  The chrome
/// (layout button + pin) is placed inline in strip mode and as a frosted-glass
/// pill overlay in compact and square modes, so it never obscures transport
/// controls or the scrubber.
public struct MiniPlayerView: View {
    @ObservedObject public var vm: MiniPlayerViewModel
    @EnvironmentObject private var windowMode: WindowModeController
    @AppStorage("appearance.colorScheme") private var colorSchemeKey = "system"
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"

    public init(vm: MiniPlayerViewModel) {
        self.vm = vm
    }

    public var body: some View {
        self.content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .background(MiniPlayerWindowSetup().frame(width: 0, height: 0).allowsHitTesting(false))
            .onAppear {
                self.applyWindowLevel()
                self.windowMode.miniPlayerOpen = true
                // Defer orderOut by one run-loop tick so the mini player's first
                // frame (including ultraThinMaterial blur) is committed before we
                // hide the main window.  Doing both in the same tick stalls the
                // main thread long enough to starve the CoreAudio render thread.
                DispatchQueue.main.async {
                    MainWindowTracker.shared.window?.orderOut(nil)
                }
            }
            .onDisappear {
                // toggleMiniPlayer sets miniPlayerOpen = false before dismissing,
                // so if it's already false here we know that path already scheduled
                // a restore.  Only act when the window was closed by other means
                // (e.g. ⌘W) to avoid a double makeKeyAndOrderFront.
                let needsRestore = self.windowMode.miniPlayerOpen
                self.windowMode.miniPlayerOpen = false
                guard needsRestore else { return }
                if let win = MainWindowTracker.shared.window {
                    win.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    self.windowMode.openWindow?("main")
                }
            }
            .onChange(of: self.vm.alwaysOnTop) { _, _ in self.applyWindowLevel() }
            .preferredColorScheme(self.preferredColorScheme)
            .tint(AccentPalette.color(for: self.accentColorKey))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mini Player")
    }

    // MARK: - Layout selection

    @ViewBuilder
    private var content: some View {
        switch self.vm.layout {
        case .strip:
            self.stripLayout

        case .compact:
            MiniPlayerCompact(vm: self.vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .overlay(alignment: .topTrailing) {
                    self.chrome.padding(6)
                }

        case .square:
            MiniPlayerSquare(vm: self.vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    self.chrome.padding(6)
                }
        }
    }

    // MARK: - Strip layout (chrome inline to avoid covering play button)

    private var stripLayout: some View {
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
            .help(self.vm.nowPlaying.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(self.vm.nowPlaying.isPlaying ? "Pause" : "Play")

            Button {
                Task { await self.vm.nowPlaying.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.nowPlaying.shuffleOn ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .help(self.vm.nowPlaying.shuffleOn ? "Shuffle: On — click to disable" : "Shuffle: Off — click to enable")
            .accessibilityLabel(self.vm.nowPlaying.shuffleOn ? "Shuffle On" : "Shuffle Off")
            .accessibilityAddTraits(.isToggle)

            Button {
                Task { await self.vm.nowPlaying.cycleRepeat() }
            } label: {
                Image(systemName: self.vm.nowPlaying.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.nowPlaying.repeatMode == .off ? Color.textTertiary : AccentPalette.color(for: self.accentColorKey))
            .help(
                "Repeat: \(self.vm.nowPlaying.repeatMode == .off ? "Off" : self.vm.nowPlaying.repeatMode == .all ? "All" : "One") — click to cycle"
            )
            .accessibilityLabel(
                "Repeat \(self.vm.nowPlaying.repeatMode == .off ? "Off" : self.vm.nowPlaying.repeatMode == .all ? "All" : "One")"
            )
            .accessibilityAddTraits(.isToggle)

            Button {
                Task { await self.vm.nowPlaying.toggleStopAfterCurrent() }
            } label: {
                Image(systemName: "stop.circle\(self.vm.nowPlaying.stopAfterCurrent ? ".fill" : "")")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.nowPlaying.stopAfterCurrent ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .help(self.vm.nowPlaying.stopAfterCurrent ? "Stop after current track: On" : "Stop after current track: Off")
            .accessibilityLabel(self.vm.nowPlaying.stopAfterCurrent ? "Stop After Current: On" : "Stop After Current: Off")
            .accessibilityAddTraits(.isToggle)

            Divider().frame(height: 14)

            self.layoutButton
            self.pinButton
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Chrome overlay (compact + square)

    /// Frosted-glass pill containing the layout and pin buttons.  The material
    /// backdrop keeps them readable over both artwork and solid backgrounds.
    private var chrome: some View {
        HStack(spacing: 4) {
            self.layoutButton
            self.pinButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Buttons

    private var layoutButton: some View {
        Button {
            self.vm.cycleLayout()
            self.resizeWindow(for: self.vm.layout)
        } label: {
            Image(systemName: self.vm.layout.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Layout: \(self.vm.layout.rawValue.capitalized) — click to cycle Strip → Compact → Square")
        .accessibilityLabel("Cycle mini player layout, currently \(self.vm.layout.rawValue)")
    }

    private var pinButton: some View {
        Button {
            self.vm.alwaysOnTop.toggle()
        } label: {
            Image(systemName: self.vm.alwaysOnTop ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(self.vm.alwaysOnTop ? Color.accentColor : Color.textTertiary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(self.vm.alwaysOnTop ? "Unpin — stop floating above other windows" : "Pin — float above other windows")
        .accessibilityLabel(self.vm.alwaysOnTop ? "Unpin mini player" : "Pin mini player above other windows")
    }

    // MARK: - Window helpers

    private func applyWindowLevel() {
        guard let window = NSApp.windows.first(where: {
            $0.title == "Mini Player" || $0.identifier?.rawValue == "mini"
        }) else { return }
        window.level = self.vm.alwaysOnTop ? .floating : .normal
    }

    private func resizeWindow(for layout: MiniPlayerViewModel.Layout) {
        guard let win = MiniPlayerWindowTracker.shared.window else { return }
        let size = layout.defaultWindowSize
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            win.animator().setContentSize(NSSize(width: size.width, height: size.height))
        }
    }

    // MARK: - Color scheme

    private var preferredColorScheme: ColorScheme? {
        switch self.colorSchemeKey {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
