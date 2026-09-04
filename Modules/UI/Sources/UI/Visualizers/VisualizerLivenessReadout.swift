import SwiftUI

// MARK: - VisualizerLivenessReadout

/// Zero-size accessibility readouts that make a visualizer surface observable
/// from XCUITest (ADR-084): the host FPS (E2E only), the mode name and the
/// palette name, each as the `.accessibilityValue` of its own element.
///
/// Three separate plain (non-adjustable) elements, each exposing one thing,
/// because two other AX roles do not reliably bridge a value to XCUITest even
/// though their label bridges fine (found empirically, ADR-084): a
/// Canvas/MTKView-backed render surface, and a plain view carrying
/// `.accessibilityAdjustableAction`, which XCUITest exposes with no `value:`
/// at all.
///
/// Applied as a modifier rather than embedded in a card so the readouts stay
/// queryable regardless of the card's own fade state: an `.opacity` or
/// `.allowsHitTesting` on a parent affects everything nested inside it.
/// Shared by every visualizer surface: the pane, mini player and fullscreen
/// window through ``VisualizerControlOverlay``, and Immersive Mode directly,
/// which has no steppers to wrap (ADR-089).
///
/// `mode` and `palette` are passed explicitly, not read from `vm`, so a
/// surface that pins its own look reports what it actually draws.
struct VisualizerLivenessReadout: ViewModifier {
    @ObservedObject var vm: VisualizerViewModel
    let mode: VisualizerMode
    let palette: VisualizerPalette

    func body(content: Content) -> some View {
        content
            .overlay {
                Text(verbatim: "\u{00A0}")
                    .frame(width: 0, height: 0)
                    .accessibilityIdentifier(A11y.Visualizer.host)
                    .modifier(LivenessAccessibilityValue(vm: self.vm))
            }
            .overlay {
                Text(verbatim: "\u{00A0}")
                    .frame(width: 0, height: 0)
                    .accessibilityIdentifier(A11y.Visualizer.modeValue)
                    .accessibilityValue(self.mode.displayName)
            }
            .overlay {
                Text(verbatim: "\u{00A0}")
                    .frame(width: 0, height: 0)
                    .accessibilityIdentifier(A11y.Visualizer.paletteValue)
                    .accessibilityValue(self.palette.displayName)
            }
    }
}

// MARK: - LivenessAccessibilityValue

/// Applies `VisualizerViewModel.currentFPS` as an accessibility value only
/// under `e2eLiveness`, never for a real user, whose accessibility tree must
/// not carry this internal metric (ADR-084). Always applies the modifier (an
/// empty value reads as no value to VoiceOver) rather than branching to a
/// differently-shaped view per condition, which resets SwiftUI's identity
/// for the wrapped content and can silently drop modifiers applied to it
/// further up the chain.
struct LivenessAccessibilityValue: ViewModifier {
    @ObservedObject var vm: VisualizerViewModel

    func body(content: Content) -> some View {
        content.accessibilityValue(
            self.vm.e2eLiveness ? L10n.string("\(Int(self.vm.currentFPS.rounded())) fps") : ""
        )
    }
}
