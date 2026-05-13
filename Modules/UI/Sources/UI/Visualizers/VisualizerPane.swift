import SwiftUI

// MARK: - VisualizerPane

/// Right-side overlay pane showing the visualizer, mutually exclusive with `LyricsPane`.
///
/// Embed this as a trailing overlay inside `BocanRootView`, replacing `LyricsPane`
/// when `vm.paneVisible` is `true`.
public struct VisualizerPane: View {
    // MARK: - Dependencies

    @ObservedObject public var vm: VisualizerViewModel

    public var nowPlayingVM: NowPlayingViewModel

    // MARK: - State

    @AppStorage("visualizer.paneWidth") private var paneWidth: Double = 300
    @State private var resizeDragStart: Double?
    @State private var overlayTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Init

    public init(vm: VisualizerViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.vm = vm
        self.nowPlayingVM = nowPlayingVM
    }

    // MARK: - Body

    public var body: some View {
        if self.vm.paneVisible {
            VStack(spacing: 0) {
                self.header
                Divider()
                ZStack(alignment: .topLeading) {
                    VisualizerHost(vm: self.vm)
                    NowPlayingOverlay(
                        title: self.nowPlayingVM.title,
                        artist: self.nowPlayingVM.artist,
                        album: self.nowPlayingVM.album,
                        fadeAfter: 3,
                        refreshTrigger: self.overlayTrigger
                    )
                }
                .onHover { _ in self.overlayTrigger += 1 }
            }
            .frame(width: self.paneWidth)
            .background(Color.black)
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 6)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    if self.resizeDragStart == nil {
                                        self.resizeDragStart = self.paneWidth
                                    }
                                    let newWidth = (self.resizeDragStart ?? self.paneWidth) - value.translation.width
                                    self.paneWidth = max(220, min(600, newWidth))
                                }
                                .onEnded { _ in self.resizeDragStart = nil }
                        )
                        .onHover { hovering in
                            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                    Divider()
                }
            }
            .accessibilityIdentifier(A11y.Visualizer.pane)
            .accessibilityLabel("Visualizer pane, \(self.vm.mode.displayName)")
            .transition(self.reduceMotion ? .opacity : .move(edge: .trailing))
            .onAppear { self.vm.start() }
            .onDisappear { self.vm.stop() }
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack(spacing: 8) {
            Text("Visualizer")
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                self.openWindow(id: "visualizer-fullscreen")
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Open fullscreen visualizer (⌘⇧F)")
            .accessibilityLabel("Open fullscreen visualizer")

            Button {
                if self.reduceMotion {
                    self.vm.paneVisible = false
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.vm.paneVisible = false
                    }
                }
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Close visualizer pane")
            .accessibilityLabel("Close visualizer pane")
            .accessibilityIdentifier(A11y.Visualizer.closeButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    @Environment(\.openWindow) private var openWindow
}
