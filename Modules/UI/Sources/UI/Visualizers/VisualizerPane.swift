import SwiftUI

// MARK: - VisualizerPane

/// Right-side overlay pane showing the visualizer, mutually exclusive with `LyricsPane`.
///
/// Embed this as a trailing overlay inside `BocanRootView`, replacing `LyricsPane`
/// when `vm.paneVisible` is `true`.
public struct VisualizerPane: View {
    // MARK: - Dependencies

    @ObservedObject public var vm: VisualizerViewModel

    // MARK: - State

    @AppStorage("visualizer.paneWidth") private var paneWidth: Double = 300

    // MARK: - Init

    public init(vm: VisualizerViewModel) {
        self.vm = vm
    }

    // MARK: - Body

    public var body: some View {
        if self.vm.paneVisible {
            VStack(spacing: 0) {
                self.header
                Divider()
                VisualizerHost(vm: self.vm)
            }
            .frame(width: self.paneWidth)
            .background(Color.black)
            .overlay(alignment: .leading) { Divider() }
            .accessibilityIdentifier(A11y.Visualizer.pane)
            .accessibilityLabel("Visualizer pane, \(self.vm.mode.displayName)")
            .transition(.move(edge: .trailing))
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.vm.paneVisible = false
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
}
