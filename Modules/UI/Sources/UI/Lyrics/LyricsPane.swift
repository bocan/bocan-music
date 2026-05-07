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
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var showOffsetPopover = false

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
                LyricsView(vm: self.vm, onSeek: self.onSeek, searchText: self.searchText)
                    .onChange(of: self.position) { _, newPos in
                        self.vm.positionDidChange(newPos)
                    }
            }
            .frame(width: self.paneWidth)
            .background(.ultraThinMaterial)
            .overlay(alignment: .leading) {
                Divider()
            }
            .sheet(isPresented: self.$vm.isEditorPresented) {
                LyricsEditorSheet(
                    vm: self.vm,
                    isPresented: self.$vm.isEditorPresented,
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

            if let label = self.vm.documentSourceLabel {
                self.sourceBadge(label)
            }

            Spacer()

            self.fontSizePicker

            if self.vm.lrclibEnabled, self.vm.document != nil {
                self.replaceWithLRClibButton
            }

            if case .synced = self.vm.document {
                self.offsetButton
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.showSearch.toggle()
                }
                if !self.showSearch { self.searchText = "" }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Find in lyrics")
            .accessibilityLabel("Search lyrics")

            Button {
                self.vm.isEditorPresented = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("Edit lyrics (⌘⌥⇧L)")
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

    private func sourceBadge(_ label: String) -> some View {
        let isSynced = if case .synced = self.vm.document { true } else { false }
        let detail = isSynced ? "Synced" : "Plain"
        return Text("\(label) · \(detail)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help("Lyrics source: \(label) (\(detail))")
            .accessibilityLabel("Lyrics source: \(label), \(detail)")
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Find in lyrics", text: self.$searchText)
                .textFieldStyle(.plain)
            if !self.searchText.isEmpty {
                Button {
                    self.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// A compact header button that opens a popover for adjusting the sync offset
    /// (−5 000 ms to +5 000 ms in 50 ms steps).  Only shown for synced documents.
    private var offsetButton: some View {
        Button {
            self.showOffsetPopover.toggle()
        } label: {
            Image(systemName: "timer")
                .symbolVariant(self.vm.userOffsetMS != 0 ? .fill : .none)
                .foregroundStyle(self.vm.userOffsetMS != 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .help(self.vm
            .userOffsetMS == 0 ? "Adjust sync offset" : "Sync offset: \(self.vm.userOffsetMS > 0 ? "+" : "")\(self.vm.userOffsetMS) ms")
        .accessibilityLabel("Adjust lyrics sync offset")
        .accessibilityIdentifier(A11y.Lyrics.offsetButton)
        .popover(isPresented: self.$showOffsetPopover, arrowEdge: .bottom) {
            self.offsetPopover
        }
    }

    private var offsetPopover: some View {
        let offsetBinding = Binding<Double>(
            get: { Double(self.vm.userOffsetMS) },
            set: { self.vm.userOffsetMS = Int($0.rounded()) }
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text("Sync Offset")
                .font(.headline)

            Slider(value: offsetBinding, in: -5000 ... 5000, step: 50) {
                Text("Offset")
            }
            .accessibilityIdentifier(A11y.Lyrics.offsetSlider)
            .frame(width: 220)

            HStack {
                Text(
                    self.vm.userOffsetMS == 0
                        ? "0 ms"
                        : "\(self.vm.userOffsetMS > 0 ? "+" : "")\(self.vm.userOffsetMS) ms"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Spacer()

                Button("Reset") {
                    self.vm.userOffsetMS = 0
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.vm.userOffsetMS == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(self.vm.userOffsetMS == 0)
            }

            Text("Shifts highlighted line timing.\nResets when the track changes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 260)
    }

    /// A compact header button that force-fetches lyrics from LRClib, replacing
    /// whatever is currently stored.  Shows a spinner while the request is live.
    private var replaceWithLRClibButton: some View {
        Group {
            if self.vm.isFetching {
                ProgressView()
                    .controlSize(.small)
                    .help("Fetching from LRClib\u{2026}")
            } else {
                Button {
                    self.vm.forceFetch()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Replace with LRClib result")
                .accessibilityLabel("Replace lyrics with LRClib result")
                .accessibilityIdentifier(A11y.Lyrics.replaceButton)
            }
        }
    }
}
