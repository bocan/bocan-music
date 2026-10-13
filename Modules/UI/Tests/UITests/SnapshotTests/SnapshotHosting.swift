import AppKit
import SnapshotTesting
import SwiftUI

// MARK: - Sparse views

/// Hosts a view that is mostly empty space, such as a `ContentUnavailableView`
/// empty state, so that its snapshot checks the icon and the copy (#641).
///
/// `host` alone does not, for three reasons that add up:
/// - The view has no background of its own, so the image is transparent. The
///   label is still drawn, but in a viewer it is white text on a white page,
///   which reads as "nothing was captured".
/// - A test that sets no colour scheme follows the appearance of the Mac it
///   runs on. The "light" Radio reference was a dark one, byte for byte.
/// - The label covers under 2% of the pixels, and the suite's usual
///   `precision: 0.98` lets 2% of them differ. A view with no label at all
///   passed. Compare with `sparseImage` to close that.
@MainActor
func hostSparse(_ view: some View, size: CGSize, dark: Bool) -> NSView {
    host(
        view
            .background(Color(nsColor: .windowBackgroundColor))
            .colorScheme(dark ? .dark : .light),
        size: size
    )
}

extension Snapshotting where Value == NSView, Format == NSImage {
    /// The strategy for a view hosted with `hostSparse`: at most one pixel in
    /// a thousand may differ, so a missing or changed title fails. The
    /// per-pixel tolerance stays at the suite's usual value, which absorbs
    /// anti-aliasing.
    static var sparseImage: Snapshotting {
        .image(precision: 0.999, perceptualPrecision: 0.98)
    }
}
