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
    @EnvironmentObject private var visualizerVM: VisualizerViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance.colorScheme") private var colorSchemeKey = "system"
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"
    /// Per-app reduce-motion toggle (Appearance Settings §3 — see issue #144).
    @AppStorage("appearance.reduceMotion") private var appReduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(vm: MiniPlayerViewModel) {
        self.vm = vm
    }

    public var body: some View {
        self.content
            // Layouts fill the window so it stays user-resizable; switching snaps the
            // window to the layout's size via resizeWindow(for:). The window uses
            // .windowResizability(.contentMinSize) so the manual snap sticks and the
            // user can still drag-resize, unlike .contentSize, which pinned the window
            // to the content's fitting size and fought the snap (a strip shown as a
            // square, a compact too short). Spring-animate the content transition.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                self.reduceMotion ? .none : .spring(response: 0.35, dampingFraction: 0.8),
                value: self.vm.layout
            )
            .adaptiveMaterial()
            .background(MiniPlayerWindowSetup().frame(width: 0, height: 0).allowsHitTesting(false))
            .onAppear {
                self.applyWindowLevel()
                self.fadeInMiniWindow()
                self.windowMode.miniPlayerOpen = true
                // Defer orderOut by one run-loop tick so the mini player's first
                // frame (including ultraThinMaterial blur) is committed before we
                // hide the main window.  Doing both in the same tick stalls the
                // main thread long enough to starve the CoreAudio render thread.
                // The fade (#330) runs inside the deferred tick for the same reason.
                DispatchQueue.main.async {
                    // Snap the window to the restored layout's size (instant: it is
                    // masked by the open fade), in case the saved layout differs from
                    // the scene's defaultSize.
                    self.resizeWindow(for: self.vm.layout, animated: false)
                    if let win = MainWindowTracker.shared.resolveWindow() {
                        WindowFade.orderOut(win)
                    }
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
                if let win = MainWindowTracker.shared.resolveWindow() {
                    WindowFade.makeKeyAndOrderFront(win)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    self.windowMode.openWindow?("main")
                }
            }
            .onChange(of: self.vm.alwaysOnTop) { _, _ in self.applyWindowLevel() }
            .onChange(of: self.vm.layout) { _, newLayout in self.resizeWindow(for: newLayout) }
            .preferredColorScheme(self.preferredColorScheme)
            .tint(AccentPalette.color(for: self.accentColorKey))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("Mini Player"))
    }

    // MARK: - Layout selection

    @ViewBuilder
    private var content: some View {
        switch self.vm.layout {
        case .strip:
            self.stripLayout
                .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case .compact:
            MiniPlayerCompact(vm: self.vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .overlay(alignment: .topTrailing) {
                    self.chrome.padding(6)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case .square:
            MiniPlayerSquare(vm: self.vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    self.chrome.padding(6)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case .visualizer:
            MiniPlayerVisualizer(vm: self.vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    self.chrome.padding(6)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    // MARK: - Strip layout (chrome inline to avoid covering play button)

    private var stripLayout: some View {
        HStack(spacing: 10) {
            MarqueeText(
                self.vm.nowPlaying.title.isEmpty ? L10n.string("Not playing") : self.vm.nowPlaying.title,
                font: .system(size: 12, weight: .medium),
                foregroundStyle: Color.textPrimary
            )
            .layoutPriority(-1)

            Spacer()

            MiniPlayerTransport(
                np: self.vm.nowPlaying,
                musicLayout: .strip,
                palette: .standard,
                spacing: 10,
                secondarySize: 14,
                primarySize: 14,
                accentSize: 12
            )

            Divider().frame(height: 14)

            self.layoutButton
            self.pinButton
            self.dismissButton
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Chrome overlay (compact + square)

    /// Inverted-colour pill containing the layout, pin, and dismiss buttons.
    /// Uses a dark background in light mode and a light background in dark mode
    /// so the icons (white / black via the inverted colorScheme environment)
    /// remain fully legible over any album art colour.  Opacity increases to
    /// 100 % when Reduce Transparency is on.
    private var chrome: some View {
        HStack(spacing: 4) {
            self.layoutButton
            self.pinButton
            self.dismissButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(
                self.colorScheme == .light
                    ? AnyShapeStyle(Color.black.opacity(self.reduceTransparency ? 1 : 0.62))
                    : AnyShapeStyle(Color.white.opacity(self.reduceTransparency ? 1 : 0.78))
            )
        )
        // Invert the colour-scheme environment so Color.primary inside the
        // buttons is white on the dark pill (light mode) and black on the
        // light pill (dark mode), giving maximum contrast over any artwork.
        .environment(\.colorScheme, self.colorScheme == .light ? .dark : .light)
    }

    // MARK: - Buttons

    private var layoutButton: some View {
        Button {
            self.vm.cycleLayout()
            // The window snap is driven by .onChange(of: vm.layout) on the body.
        } label: {
            Image(systemName: self.vm.layout.icon)
                .scaledSystemFont(size: 11, weight: .medium)
                .foregroundStyle(Color.primary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.string(
            "Layout: \(self.vm.layout.rawValue.capitalized) — click to cycle Strip → Compact → Square → Visualizer"
        ))
        .accessibilityLabel(L10n.string("Cycle mini player layout, currently \(self.vm.layout.rawValue)"))
    }

    private var pinButton: some View {
        Button {
            self.vm.alwaysOnTop.toggle()
        } label: {
            Image(systemName: self.vm.alwaysOnTop ? "pin.fill" : "pin")
                .scaledSystemFont(size: 11, weight: .medium)
                .foregroundStyle(self.vm.alwaysOnTop ? Color.accentColor : Color.primary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(self.vm.alwaysOnTop
            ? L10n.string("Unpin — stop floating above other windows")
            : L10n.string("Pin — float above other windows"))
        .accessibilityLabel(self.vm.alwaysOnTop
            ? L10n.string("Unpin mini player")
            : L10n.string("Pin mini player above other windows"))
    }

    private var dismissButton: some View {
        Button {
            self.windowMode.toggleMiniPlayer()
        } label: {
            Image(systemName: "xmark")
                .scaledSystemFont(size: 11, weight: .medium)
                .foregroundStyle(Color.primary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.string("Return to main window"))
        .accessibilityLabel(L10n.string("Return to main window"))
    }

    // MARK: - Window helpers

    /// `true` when either the system-level or per-app reduce-motion preference is active.
    private var reduceMotion: Bool {
        self.systemReduceMotion || self.appReduceMotion
    }

    private func applyWindowLevel() {
        guard let window = NSApp.windows.first(where: {
            $0.title == "Mini Player" || $0.identifier?.rawValue == "mini"
        }) else { return }
        window.level = self.vm.alwaysOnTop ? .floating : .normal
    }

    /// Cross-fade (#330): fade the freshly-opened mini window in from
    /// transparent. `WindowFade` no-ops under reduce motion.
    private func fadeInMiniWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.title == "Mini Player" || $0.identifier?.rawValue == "mini"
        }) else { return }
        WindowFade.fadeIn(window)
    }

    /// The mini-player NSWindow, found the same reliable way `applyWindowLevel`
    /// and `fadeInMiniWindow` find it (not the weak tracker).
    private var miniWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Mini Player" || $0.identifier?.rawValue == "mini" }
    }

    /// Snaps the mini-player window to `layout`'s default size. Animated on a user
    /// layout switch; instant on open. A user drag is ephemeral: frame autosave is
    /// cleared so the OS neither persists the resized size nor re-applies it on a
    /// layout change (which would override this snap and make the resize "stick").
    private func resizeWindow(for layout: MiniPlayerViewModel.Layout, animated: Bool = true) {
        guard let win = self.miniWindow else { return }
        win.setFrameAutosaveName("")
        let size = layout.defaultWindowSize
        let targetSize = NSSize(width: size.width, height: size.height)
        guard animated, !self.reduceMotion else {
            win.setContentSize(targetSize)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            // Approximate spring(response: 0.35, dampingFraction: 0.8): a slight
            // overshoot matches the SwiftUI spring on the content inside the window.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.2, 0.64, 1.0)
            win.animator().setContentSize(targetSize)
        }
    }

    // MARK: - Color scheme

    private var preferredColorScheme: ColorScheme? {
        switch self.colorSchemeKey {
        case "light":
            .light

        case "dark":
            .dark

        default:
            nil
        }
    }
}
