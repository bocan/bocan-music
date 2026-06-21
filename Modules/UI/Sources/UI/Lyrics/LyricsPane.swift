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

    @AppStorage("lyrics.paneWidth") private var paneWidth: Double = 280
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var showOffsetPopover = false
    @State private var resizeDragStart: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
            .background {
                if self.reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Color.clear.background(.ultraThinMaterial)
                }
            }
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
            .sheet(isPresented: self.$vm.isEditorPresented) {
                LyricsEditorSheet(
                    vm: self.vm,
                    isPresented: self.$vm.isEditorPresented,
                    currentPosition: self.position
                )
            }
            .accessibilityIdentifier(A11y.Lyrics.pane)
            .transition(self.reduceMotion ? .opacity : .move(edge: .trailing))
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: title, source badge, close
            HStack(spacing: 6) {
                Text(localized: "Lyrics")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                if let label = self.vm.documentSourceLabel {
                    self.sourceBadge(label)
                }

                Spacer()

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
                }
                .buttonStyle(.plain)
                .help(L10n.string("Close lyrics pane (⌘L)"))
                .accessibilityLabel(L10n.string("Close lyrics pane"))
                .accessibilityIdentifier(A11y.Lyrics.closeButton)
            }

            // Row 2: font-size picker + action buttons
            HStack(spacing: 6) {
                self.fontSizePicker

                Spacer()

                if self.vm.lrclibEnabled, self.vm.document != nil {
                    self.replaceWithLRClibButton
                }

                if case .synced = self.vm.document {
                    self.offsetButton
                }

                Button {
                    if self.reduceMotion {
                        self.showSearch.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            self.showSearch.toggle()
                        }
                    }
                    if !self.showSearch { self.searchText = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help(L10n.string("Find in lyrics"))
                .accessibilityLabel(L10n.string("Search lyrics"))

                Button {
                    self.vm.isEditorPresented = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help(L10n.string("Edit lyrics (⌘⌥⇧L)"))
                .accessibilityLabel(L10n.string("Edit lyrics"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func sourceBadge(_ label: String) -> some View {
        let isSynced = if case .synced = self.vm.document { true } else { false }
        let detail = isSynced ? L10n.string("Synced") : L10n.string("Plain")
        return Text(localized: "\(label) · \(detail)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help(L10n.string("Lyrics source: \(label) (\(detail))"))
            .accessibilityLabel(L10n.string("Lyrics source: \(label), \(detail)"))
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
                .help(L10n.string("\(size.fullName) font size"))
                .accessibilityLabel(L10n.string("\(size.fullName) font size"))
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField(L10n.string("Find in lyrics"), text: self.$searchText)
                .textFieldStyle(.plain)
            if !self.searchText.isEmpty {
                Button {
                    self.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Clear search"))
                .accessibilityLabel(L10n.string("Clear search"))
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
        .help(self.vm.userOffsetMS == 0
            ? L10n.string("Adjust sync offset")
            : L10n.string("Sync offset: \(self.vm.userOffsetMS > 0 ? "+" : "")\(self.vm.userOffsetMS) ms"))
        .accessibilityLabel(L10n.string("Adjust lyrics sync offset"))
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
            Text(localized: "Sync Offset")
                .font(.headline)

            Slider(value: offsetBinding, in: -5000 ... 5000, step: 50) {
                Text(localized: "Offset")
            }
            .accessibilityIdentifier(A11y.Lyrics.offsetSlider)
            .accessibilityValue(self.offsetValueLabel)
            .frame(width: 220)

            HStack {
                Text(verbatim: self.offsetValueLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button(L10n.string("Reset")) {
                    self.vm.userOffsetMS = 0
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.vm.userOffsetMS == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(self.vm.userOffsetMS == 0)
            }

            Text(localized: "Shifts highlighted line timing.\nResets when the track changes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 260)
    }

    /// Signed millisecond readout shown under the offset slider and announced as the
    /// slider's accessibility value (so VoiceOver reads "+250 ms", not a percentage).
    private var offsetValueLabel: String {
        self.vm.userOffsetMS == 0
            ? "0 ms"
            : "\(self.vm.userOffsetMS > 0 ? "+" : "")\(self.vm.userOffsetMS) ms"
    }

    /// A compact header button that force-fetches lyrics from LRClib, replacing
    /// whatever is currently stored.  Shows a spinner while the request is live.
    private var replaceWithLRClibButton: some View {
        Group {
            if self.vm.isFetching {
                ProgressView()
                    .controlSize(.small)
                    .help(L10n.string("Fetching from LRClib\u{2026}"))
            } else {
                Button {
                    self.vm.forceFetch()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(L10n.string("Replace with LRClib result"))
                .accessibilityLabel(L10n.string("Replace lyrics with LRClib result"))
                .accessibilityIdentifier(A11y.Lyrics.replaceButton)
            }
        }
    }
}
