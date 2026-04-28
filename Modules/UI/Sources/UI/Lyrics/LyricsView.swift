import Metadata
import SwiftUI

// MARK: - LyricsView

/// Renders a ``LyricsDocument`` as either a scrollable text block (unsynced)
/// or a per-line list with the current line highlighted (synced).
///
/// Drive `currentLineIndex` from ``LyricsViewModel/positionDidChange(_:)`` on
/// every engine position tick; the view scrolls only when the index changes to
/// avoid jitter (see *Gotchas* in `phase-11-lyrics.md`).
public struct LyricsView: View {
    // MARK: - Dependencies

    @ObservedObject public var vm: LyricsViewModel

    /// Seek the engine when the user taps a synced line.
    public var onSeek: (TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Init

    public init(vm: LyricsViewModel, onSeek: @escaping (TimeInterval) -> Void) {
        self.vm = vm
        self.onSeek = onSeek
    }

    // MARK: - Body

    public var body: some View {
        switch self.vm.document {
        case .none:
            self.emptyState

        case let .unsynced(text):
            self.unsyncedView(text: text)

        case let .synced(lines, _):
            self.syncedView(lines: lines)
        }
    }

    // MARK: - Sub-views

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Lyrics")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Paste lyrics in the editor or fetch from LRClib.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11y.Lyrics.emptyState)
    }

    private func unsyncedView(text: String) -> some View {
        ScrollView {
            Text(text)
                .font(self.vm.fontSizeKey.font)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
        }
        .accessibilityIdentifier(A11y.Lyrics.unsyncedScroll)
    }

    private func syncedView(lines: [LyricsDocument.LyricsLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        SyncedLineRow(
                            line: line,
                            isCurrent: idx == self.vm.currentLineIndex,
                            font: self.vm.fontSizeKey.font
                        ) { self.onSeek(line.start) }
                            .id(idx)
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            }
            .onChange(of: self.vm.currentLineIndex) { _, newIndex in
                guard let idx = newIndex else { return }
                withAnimation(self.reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
        .accessibilityIdentifier(A11y.Lyrics.syncedScroll)
    }
}

// MARK: - SyncedLineRow

/// A single row in the synced lyrics list.
private struct SyncedLineRow: View {
    let line: LyricsDocument.LyricsLine
    let isCurrent: Bool
    let font: Font
    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            Text(self.line.text)
                .font(self.font)
                .fontWeight(self.isCurrent ? .semibold : .regular)
                .foregroundStyle(self.isCurrent ? Color.accentColor : Color.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.2), value: self.isCurrent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(self.line.text)
        .accessibilityAddTraits(self.isCurrent ? [.isSelected] : [])
        .accessibilityHint("Seek to this line")
    }
}
