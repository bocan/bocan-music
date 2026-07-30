import SwiftUI

// MARK: - AlbumOpenPlayGesture

/// Click handling for album covers (#369): double-click plays the album in
/// place, a single click opens its track list.
///
/// The two are composed exclusively with the double-click taking precedence,
/// so a single click commits only after the double-click window closes. That
/// disambiguation pause is inherent to giving one target two click outcomes;
/// the platform's alternative (single click selects, double click acts) would
/// change every existing browse habit in the app.
struct AlbumOpenPlayGesture: ViewModifier {
    let open: () -> Void
    let play: () -> Void

    func body(content: Content) -> some View {
        content.gesture(
            TapGesture(count: 2)
                .onEnded { self.play() }
                .exclusively(
                    before: TapGesture()
                        .onEnded { self.open() }
                )
        )
    }
}

extension View {
    /// Double-click runs `play` in place; a single click runs `open` once the
    /// double-click window has closed (#369).
    func albumOpenPlayGesture(open: @escaping () -> Void, play: @escaping () -> Void) -> some View {
        self.modifier(AlbumOpenPlayGesture(open: open, play: play))
    }
}
