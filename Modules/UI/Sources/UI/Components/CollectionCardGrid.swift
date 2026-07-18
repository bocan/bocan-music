import SwiftUI

// MARK: - CollectionCardGrid

/// An adaptive `LazyVGrid` of ``CollectionCard``s, mirroring `AlbumsGridView`'s
/// grid metrics exactly (`@ScaledMetric` minimum width, shared spacing).
///
/// Open-on-click is handled here; `onOpen` receives the card id. Scroll offset
/// is owned by the caller (via `scrollOffset`) so it survives the grid rebuild
/// on return from a destination, following the #349 restore pattern. An
/// optional per-card context-menu builder is threaded through generically.
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

    /// Scales the minimum card width proportionally to the user's text size,
    /// identical to `AlbumsGridView`.
    @ScaledMetric(relativeTo: .body) private var scaledMinWidth = Theme.albumGridMinWidth
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var liveScrollOffset: CGFloat = 0

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
        // reload, mirroring `AlbumsGridView`.
        .onAppear { self.restoreScrollOffset() }
        .onChange(of: self.models.map(\.id)) { _, _ in self.restoreScrollOffset() }
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
