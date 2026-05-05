import SwiftUI

// MARK: - RoutePicker

/// Combined route indicator + AirPlay picker for the now-playing strip.
public struct RoutePicker: View {
    var vm: RouteViewModel

    public init(vm: RouteViewModel) {
        self.vm = vm
    }

    public var body: some View {
        HStack(spacing: 6) {
            ActiveRouteChip(vm: self.vm)
            AirPlayButton()
                .frame(width: 22, height: 22)
                .help("Choose AirPlay output")
                .accessibilityLabel("Choose AirPlay output")
        }
    }
}
