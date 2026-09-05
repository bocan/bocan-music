import SwiftUI

// MARK: - ImmersiveView

/// Immersive Mode (ADR-089): a full-window now-playing arrangement laid over
/// an Oscilloscope visualizer in the Drift palette. Three translucent cards
/// sit in a compact cluster at the centre of the window: artwork, track text
/// and the player controls; the play queue; and the lyrics. Every card is
/// built from a view the app already has (``QueueView``, ``LyricsView``,
/// ``NowPlayingViewModel``), so playback, queue edits and lyrics behave
/// exactly as they do in the normal window.
///
/// The cluster is sized by the queue: ten rows tall, and the queue scrolls
/// for anything past that. The other two cards match that height, so the
/// visualizer keeps most of the window rather than three empty columns.
///
/// The visualizer is pinned through `VisualizerHost.init(vm:mode:palette:)`;
/// the user's saved visualizer preference is never written. The overlay
/// forces a dark scheme so the cards read as dark glass on the black field
/// in both system appearances.
///
/// This view owns its visualizer lifecycle: one `start()` on appear and one
/// `stop()` on disappear, the same refcounted pairing as the pane, the mini
/// player and the fullscreen window.
public struct ImmersiveView: View {
    // MARK: - Dependencies

    @ObservedObject private var library: LibraryViewModel
    @ObservedObject private var lyricsVM: LyricsViewModel
    @ObservedObject private var visualizerVM: VisualizerViewModel
    private let onClose: () -> Void

    // MARK: - Constants

    /// The look this surface always draws, regardless of the saved preference.
    static let visualizerMode: VisualizerMode = .oscilloscope
    static let visualizerPalette: VisualizerPalette = .drift

    /// The queue card shows this many rows before it scrolls, and every card
    /// takes its height from it.
    static let queueVisibleRows = 10
    /// One inset `List` row of `QueueRow` (a single 11pt line with insets).
    static let queueRowHeight: CGFloat = 30
    /// The "Up Next" and "Lyrics" header rows.
    static let headerHeight: CGFloat = 36

    /// The gap around and between the cards, where the visualizer shows.
    private let gutter: CGFloat = 16
    /// The now-playing card is fixed; the queue and lyrics cards share the rest.
    private let nowPlayingWidth: CGFloat = 300
    /// The cluster never grows past this, however wide the window is.
    private let maxClusterWidth: CGFloat = 960

    private var clusterHeight: CGFloat {
        Self.headerHeight + 1 + CGFloat(Self.queueVisibleRows) * Self.queueRowHeight + 8
    }

    // MARK: - Init

    public init(
        library: LibraryViewModel,
        lyricsVM: LyricsViewModel,
        visualizerVM: VisualizerViewModel,
        onClose: @escaping () -> Void
    ) {
        self.library = library
        self.lyricsVM = lyricsVM
        self.visualizerVM = visualizerVM
        self.onClose = onClose
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            VisualizerHost(vm: self.visualizerVM, mode: Self.visualizerMode, palette: Self.visualizerPalette)
                // The E2E liveness readouts without the steppers: the
                // steppers would be lies on a pinned surface.
                .modifier(VisualizerLivenessReadout(
                    vm: self.visualizerVM,
                    mode: Self.visualizerMode,
                    palette: Self.visualizerPalette
                ))

            HStack(spacing: self.gutter) {
                // No card: the artwork, text and controls float on the
                // visualizer, so the cluster is two glass cards beside a
                // hero, not three equal boxes.
                ImmersiveNowPlayingColumn(vm: self.library.nowPlaying)
                    .immersivePanel(surface: false)
                    .frame(width: self.nowPlayingWidth)
                    .accessibilityIdentifier(A11y.Immersive.nowPlayingColumn)

                self.queueColumn
                    .immersivePanel()
                    .accessibilityIdentifier(A11y.Immersive.queueColumn)

                self.lyricsColumn
                    .immersivePanel()
                    .accessibilityIdentifier(A11y.Immersive.lyricsColumn)
            }
            .frame(maxWidth: self.maxClusterWidth)
            .frame(height: self.clusterHeight)
            .padding(self.gutter)
        }
        .overlay(alignment: .bottomTrailing) {
            self.closeButton
                .padding(self.gutter + 4)
        }
        .environment(\.colorScheme, .dark)
        .onAppear { self.visualizerVM.start() }
        .onDisappear { self.visualizerVM.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Immersive Mode"))
        .accessibilityIdentifier(A11y.Immersive.root)
    }

    // MARK: - Columns

    private var queueColumn: some View {
        VStack(spacing: 0) {
            self.columnHeader(L10n.string("Up Next"))
            // The List's own background would paint over the card; the
            // rows keep their inset style. The card's fixed height is what
            // makes the list scroll past ten rows.
            QueueView(vm: self.library)
                .scrollContentBackground(.hidden)
        }
    }

    private var lyricsColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                self.columnHeader(L10n.string("Lyrics"))
                Spacer()
                if case .synced = self.lyricsVM.document {
                    LyricsOffsetControl(vm: self.lyricsVM)
                        .padding(.trailing, 14)
                }
            }
            LyricsView(vm: self.lyricsVM) { position in
                Task { await self.library.nowPlaying.scrub(to: position) }
            }
        }
    }

    /// A quiet caption, no rule beneath it: the card edge is the frame.
    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.headerHeight)
            .padding(.horizontal, 14)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Close

    private var closeButton: some View {
        Button {
            self.onClose()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help(L10n.string("Exit Immersive Mode (Esc)"))
        .accessibilityLabel(L10n.string("Exit Immersive Mode"))
        .accessibilityIdentifier(A11y.Immersive.close)
    }
}
