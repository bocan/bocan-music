import Foundation

// MARK: - Route

/// The audio output route the app is currently using.
///
/// macOS routes audio at the system level — apps don't pick AirPlay
/// destinations directly; the user does, via the system picker. `Route`
/// is therefore an *observation* of where audio is going, not a
/// command. `RouteManager` updates it from CoreAudio HAL events.
public enum Route: Sendable, Hashable, Identifiable {
    /// Built-in speakers or wired headphones.
    case local(name: String)

    /// AirPlay-routed device (HomePod, Apple TV, AirPlay 2 speaker, …).
    case airPlay(name: String)

    /// Anything else: Bluetooth, HDMI, USB DAC, aggregate, virtual.
    /// `kind` is the human-readable transport label ("Bluetooth", "HDMI", …).
    case external(name: String, kind: String)

    /// Stable identity for SwiftUI lists.
    public var id: String {
        switch self {
        case let .local(name):
            "local:\(name)"

        case let .airPlay(name):
            "airplay:\(name)"

        case let .external(name, kind):
            "external:\(kind):\(name)"
        }
    }

    /// What the user sees in the chip.
    public var displayName: String {
        switch self {
        case let .local(name), let .airPlay(name), let .external(name, _):
            name
        }
    }

    /// Optional secondary label, used by the chip below the device name.
    public var subtitle: String? {
        switch self {
        case .local:
            nil

        case .airPlay:
            "AirPlay"

        case let .external(_, kind):
            kind
        }
    }

    /// SF Symbol that best represents this route in the UI.
    public var iconSystemName: String {
        switch self {
        case let .local(name):
            Self.localIcon(for: name)

        case .airPlay:
            "hifispeaker.fill"

        case let .external(_, kind):
            Self.externalIcon(for: kind)
        }
    }

    /// `true` when the route is the on-Mac speaker / headphones path.
    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    // MARK: - Icon helpers

    private static func localIcon(for name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("headphone") || lowered.contains("airpod") {
            return "headphones"
        }
        return "speaker.wave.2.fill"
    }

    private static func externalIcon(for kind: String) -> String {
        switch kind.lowercased() {
        case "bluetooth":
            "headphones"

        case "hdmi", "displayport":
            "tv.fill"

        case "usb", "thunderbolt":
            "speaker.wave.3.fill"

        default:
            "speaker.wave.2.fill"
        }
    }
}
