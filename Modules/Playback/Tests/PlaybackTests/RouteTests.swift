import Foundation
import Testing
@testable import Playback

// MARK: - RouteTests

@Suite("Route")
struct RouteTests {
    @Test("id is stable for same case + name")
    func idStable() {
        #expect(Route.local(name: "Speakers").id == Route.local(name: "Speakers").id)
        #expect(Route.airPlay(name: "Living Room").id == Route.airPlay(name: "Living Room").id)
        #expect(
            Route.external(name: "Bose", kind: "Bluetooth").id
                == Route.external(name: "Bose", kind: "Bluetooth").id
        )
    }

    @Test("id differs across cases and names")
    func idDiffers() {
        #expect(Route.local(name: "A").id != Route.local(name: "B").id)
        #expect(Route.local(name: "A").id != Route.airPlay(name: "A").id)
        #expect(
            Route.external(name: "X", kind: "Bluetooth").id
                != Route.external(name: "X", kind: "USB").id
        )
    }

    @Test("displayName surfaces the device name")
    func displayName() {
        #expect(Route.local(name: "Built-in").displayName == "Built-in")
        #expect(Route.airPlay(name: "HomePod").displayName == "HomePod")
        #expect(Route.external(name: "AirPods", kind: "Bluetooth").displayName == "AirPods")
    }

    @Test("subtitle is non-nil only for airPlay and external")
    func subtitle() {
        #expect(Route.local(name: "Speakers").subtitle == nil)
        #expect(Route.airPlay(name: "TV").subtitle == "AirPlay")
        #expect(Route.external(name: "AirPods", kind: "Bluetooth").subtitle == "Bluetooth")
    }

    @Test("isLocal only true for local case")
    func isLocal() {
        #expect(Route.local(name: "x").isLocal)
        #expect(!Route.airPlay(name: "x").isLocal)
        #expect(!Route.external(name: "x", kind: "k").isLocal)
    }

    @Test("local icon picks headphones for headphone-like names")
    func localIconHeadphones() {
        #expect(Route.local(name: "External Headphones").iconSystemName == "headphones")
        #expect(Route.local(name: "AirPods Pro").iconSystemName == "headphones")
        #expect(Route.local(name: "Built-in Speaker").iconSystemName == "speaker.wave.2.fill")
    }

    @Test("airPlay icon is the speaker fill")
    func airPlayIcon() {
        #expect(Route.airPlay(name: "TV").iconSystemName == "hifispeaker.fill")
    }

    @Test("external icon respects transport kind")
    func externalIcon() {
        #expect(Route.external(name: "x", kind: "Bluetooth").iconSystemName == "headphones")
        #expect(Route.external(name: "x", kind: "HDMI").iconSystemName == "tv.fill")
        #expect(Route.external(name: "x", kind: "USB").iconSystemName == "speaker.wave.3.fill")
        #expect(Route.external(name: "x", kind: "Aggregate").iconSystemName == "speaker.wave.2.fill")
    }
}

// MARK: - TransportTypeTests

@Suite("TransportType")
struct TransportTypeTests {
    @Test("kindLabel matches the human label per case")
    func labels() {
        #expect(TransportType.builtIn.kindLabel == "Built-in")
        #expect(TransportType.airPlay.kindLabel == "AirPlay")
        #expect(TransportType.bluetooth.kindLabel == "Bluetooth")
        #expect(TransportType.bluetoothLE.kindLabel == "Bluetooth")
        #expect(TransportType.hdmi.kindLabel == "HDMI")
        #expect(TransportType.displayPort.kindLabel == "DisplayPort")
        #expect(TransportType.usb.kindLabel == "USB")
        #expect(TransportType.thunderbolt.kindLabel == "Thunderbolt")
        #expect(TransportType.aggregate.kindLabel == "Aggregate")
        #expect(TransportType.virtual.kindLabel == "Virtual")
        #expect(TransportType.unknown.kindLabel == "External")
    }

    @Test("rawCode 0 maps to .unknown")
    func unknownRawCode() {
        #expect(TransportType(rawCode: 0) == .unknown)
    }
}
