import AVKit
import SwiftUI

// MARK: - AirPlayButton

/// Wraps `AVRoutePickerView` so a SwiftUI button presents the system AirPlay picker.
///
/// We deliberately don't restyle the view — picking AirPlay devices is a
/// system-owned interaction and Apple's HIG asks us to keep the standard
/// button shape. We only constrain its size to fit the transport strip.
public struct AirPlayButton: NSViewRepresentable {
    public init() {}

    public func makeNSView(context _: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.controlAccentColor, for: .normal)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        view.setAccessibilityLabel("AirPlay")
        view.toolTip = "Choose AirPlay output"
        return view
    }

    public func updateNSView(_: AVRoutePickerView, context _: Context) {
        // Stateless — system manages the picker.
    }
}
