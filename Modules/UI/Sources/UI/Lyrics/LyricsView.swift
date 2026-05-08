import Metadata
import SwiftUI

// MARK: - LyricsView

/// Renders a ``LyricsDocument`` as either a scrollable text block (unsynced)
/// or a per-line list with the current line highlighted (synced).
///
/// Drive `currentLineIndex` from ``LyricsViewModel/positionDidChange(_:)`` on
/// every engine position tick; the view scrolls only when the index changes to
/// avoid jitter (see *Gotchas* in `phase-11-lyrics.md`).
///
/// Pass a non-empty `searchText` to filter visible lines in both unsynced and
/// synced modes.  An empty string (the default) shows all content.
public struct LyricsView: View {
    // MARK: - Dependencies

    @ObservedObject public var vm: LyricsViewModel

    /// Seek the engine when the user taps a synced line.
    public var onSeek: (TimeInterval) -> Void

    /// Case-insensitive filter applied to displayed lines.  Empty = no filter.
    public var searchText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Init

    public init(
        vm: LyricsViewModel,
        onSeek: @escaping (TimeInterval) -> Void,
        searchText: String = ""
    ) {
        self.vm = vm
        self.onSeek = onSeek
        self.searchText = searchText
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
        Group {
            if self.vm.isFetching {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Fetching lyrics\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Fetching lyrics")
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No Lyrics")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    if self.vm.lrclibEnabled {
                        Button("Fetch from LRClib") {
                            self.vm.forceFetch()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier(A11y.Lyrics.fetchButton)
                    } else {
                        Text("Paste lyrics in the editor, or enable LRClib in Settings.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11y.Lyrics.emptyState)
    }

    private func unsyncedView(text: String) -> some View {
        let displayText: String = {
            guard !self.searchText.isEmpty else { return text }
            let matches = text.components(separatedBy: "\n")
                .filter { $0.localizedCaseInsensitiveContains(self.searchText) }
            return matches.isEmpty ? "" : matches.joined(separator: "\n")
        }()

        return ScrollView {
            if displayText.isEmpty, !self.searchText.isEmpty {
                self.noMatchesView
            } else {
                Text(displayText)
                    .font(self.vm.fontSizeKey.font)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(displayText)
            }
        }
        .accessibilityIdentifier(A11y.Lyrics.unsyncedScroll)
    }

    private func syncedView(lines: [LyricsDocument.LyricsLine]) -> some View {
        // Keep original indices so `isCurrent` works correctly after filtering.
        let displayLines: [(Int, LyricsDocument.LyricsLine)] = {
            let enumerated = Array(lines.enumerated())
            guard !self.searchText.isEmpty else { return enumerated }
            return enumerated.filter { $1.text.localizedCaseInsensitiveContains(self.searchText) }
        }()

        return ScrollViewReader { proxy in
            ScrollView {
                if displayLines.isEmpty {
                    self.noMatchesView
                        .padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(displayLines, id: \.0) { idx, line in
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
            }
            .onChange(of: self.vm.currentLineIndex) { _, newIndex in
                // Suppress auto-scroll during search — position may be off-screen.
                guard let idx = newIndex, self.searchText.isEmpty else { return }
                withAnimation(self.reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
        .accessibilityIdentifier(A11y.Lyrics.syncedScroll)
    }

    private var noMatchesView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No matches for \u{201C}\(self.searchText)\u{201D}")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("No lyrics match the search term \(self.searchText)")
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
