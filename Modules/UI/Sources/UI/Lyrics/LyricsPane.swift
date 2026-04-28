import Metadata
import SwiftUI

// MARK: - LyricsPane

/// The right-side overlay pane for lyrics, toggled by `⌘L` and a toolbar button.
///
/// Embed this as a trailing overlay inside `BocanRootView`.  State is persisted
/// via `@AppStorage` on ``LyricsViewModel/paneVisible``.
public struct LyricsPane: View {
    // MARK: - Dependencies

    @ObservedObject public var vm: LyricsViewModel

    /// Current engine position, forwarded to ``LyricsView`` for line highlight.
    public var position: TimeInterval

    /// Seek callback forwarded to ``LyricsView`` when the user taps a synced line.
    public var onSeek: (TimeInterval) -> Void

    // MARK: - State

    @AppStorage("lyrics.paneWidth") private var paneWidth: Double = 260
    @State private var showEditor = false
    @State private var searchText = ""
    @State private var showSearch = false

    // MARK: - Init

    public init(
        vm: LyricsViewModel,
        position: TimeInterval,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.vm = vm
        self.position = position
        self.onSeek = onSeek
    }

    // MARK: - Body

    public var body: some View {
        if self.vm.paneVisible {
            VStack(spacing: 0) {
                self.header
                Divider()
                if self.showSearch {
                    self.searchBar
                    Divider()
                }
                LyricsView(vm: self.vm, onSeek: self.onSeek)
                    .onChange(of: self.position) { _, newPos in
                        self.vm.positionDidChange(newPos)
                    }
            }
            .frame(width: self.paneWidth)
            .background(.ultraThinMaterial)
            .overlay(alignment: .leading) {
                Divider()
            }
            .sheet(isPresented: self.$showEditor) {
                LyricsEditorSheet(
                    vm: self.vm,
                    isPresented: self.$showEditor,
                    currentPosition: self.position
                )
            }
            .accessibilityIdentifier(A11y.Lyrics.pane)
            .transition(.move(edge: .trailing))
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack(spacing: 8) {
            Text("Lyrics")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            self.fontSizePicker

            Button {
                self.showSearch.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Find in lyrics (⌘F)")
            .accessibilityLabel("Search lyrics")
            .keyboardShortcut("f", modifiers: .command)

            Button {
                self.showEditor = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("Edit lyrics (⌘⌥L)")
            .accessibilityLabel("Edit lyrics")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.vm.paneVisible = false
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close lyrics pane (⌘L)")
            .accessibilityLabel("Close lyrics pane")
            .accessibilityIdentifier(A11y.Lyrics.closeButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var fontSizePicker: some View {
        HStack(spacing: 2) {
            ForEach(LyricsFontSize.allCases, id: \.self) { size in
                Button(size.label) {
                    self.vm.fontSizeKey = size
                }
                .buttonStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    self.vm.fontSizeKey == size
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear
                )
                .cornerRadius(4)
                .accessibilityLabel("Font size \(size.label)")
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: self.$searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
