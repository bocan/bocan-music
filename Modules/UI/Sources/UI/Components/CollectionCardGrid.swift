import SwiftUI

// MARK: - CollectionCardGrid

/// An adaptive `LazyVGrid` of ``CollectionCard``s, mirroring `AlbumsGridView`'s
/// grid metrics exactly (`@ScaledMetric` minimum width, shared spacing).
///
/// Open-on-click is handled here; `onOpen` receives the card id. Scroll offset
/// is owned by the caller (via `scrollOffset`) so it survives the grid rebuild
/// on return from a destination, following the #349 restore pattern. An
/// optional per-card context-menu builder is threaded through generically.
///
/// When the caller passes the live `searchQuery`, the grid also remembers where
/// the user was when a search began and returns there when the query clears in
/// place (Esc, backspace, the field's clear button) — the same "every list
/// remembers its place" promise, extended to searching (#399).
struct CollectionCardGrid<MenuContent: View>: View {
    let models: [CollectionCardModel]
    /// Placeholder SF Symbol for cards with no covers (per section).
    let placeholderSymbol: String
    /// Per-card localized accessibility hint (per section).
    let cardAccessibilityHint: String
    /// Called with a card id when the user opens it (click or Return).
    let onOpen: (String) -> Void
    /// Optional per-card context menu. `scrollOffset` follows so the two
    /// closures stay labelled (no trailing-closure ambiguity at call sites).
    @ViewBuilder let contextMenu: (CollectionCardModel) -> MenuContent
    /// Persisted live scroll offset, owned by the caller's view model so it
    /// survives this view's rebuild on return from a destination.
    @Binding var scrollOffset: Double
    /// The active toolbar search query; drives the pre-search scroll anchor.
    var searchQuery = ""

    /// Scales the minimum card width proportionally to the user's text size,
    /// identical to `AlbumsGridView`.
    @ScaledMetric(relativeTo: .body) private var scaledMinWidth = Theme.albumGridMinWidth
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var liveScrollOffset: CGFloat = 0
    /// Where the user was when the current search began; consumed on clear.
    @State private var preSearchOffset: Double?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: self.scaledMinWidth), spacing: Theme.albumGridSpacing)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: self.columns, spacing: Theme.albumGridSpacing) {
                ForEach(self.models) { model in
                    CollectionCard(
                        model: model,
                        placeholderSymbol: self.placeholderSymbol,
                        accessibilityHint: self.cardAccessibilityHint
                    )
                    .padding(4)
                    .contentShape(Rectangle())
                    .onTapGesture { self.open(model) }
                    .contextMenu { self.contextMenu(model) }
                }
            }
            .padding(Theme.albumGridSpacing)
        }
        .scrollPosition(self.$scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, newY in
            self.liveScrollOffset = newY
        }
        // Restore the saved offset when the grid (re)appears or its contents
        // reload, mirroring `AlbumsGridView`. Content changes caused by an
        // active filter must not re-apply the drill-in offset — filtered
        // results read from the top.
        .onAppear { self.restoreScrollOffset() }
        .onChange(of: self.models.map(\.id)) { _, _ in
            guard self.trimmedQuery.isEmpty else { return }
            self.restoreScrollOffset()
        }
        .onChange(of: self.searchQuery) { old, new in
            self.handleSearchTransition(old: old, new: new)
        }
    }

    private var trimmedQuery: String {
        self.searchQuery.trimmingCharacters(in: .whitespaces)
    }

    /// A search beginning snapshots where the user was and shows the filtered
    /// cards from the top; the query clearing in place puts the snapshot into
    /// the caller's slot and returns there (#399).
    private func handleSearchTransition(old: String, new: String) {
        let wasActive = !old.trimmingCharacters(in: .whitespaces).isEmpty
        let isActive = !new.trimmingCharacters(in: .whitespaces).isEmpty
        if !wasActive, isActive {
            self.preSearchOffset = Double(self.liveScrollOffset)
            self.scrollPosition.scrollTo(edge: .top)
        } else if wasActive, !isActive {
            if let anchor = self.preSearchOffset {
                self.scrollOffset = anchor
                self.preSearchOffset = nil
            }
            self.restoreScrollOffset()
        }
    }

    /// Snapshots the current offset, then opens the card. The snapshot survives
    /// the grid rebuild so the caller can restore it on return.
    private func open(_ model: CollectionCardModel) {
        self.scrollOffset = Double(self.liveScrollOffset)
        self.onOpen(model.id)
    }

    private func restoreScrollOffset() {
        guard self.scrollOffset > 0 else { return }
        self.scrollPosition.scrollTo(y: CGFloat(self.scrollOffset))
    }
}
