import AppKit
import Playback
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

// MARK: - Routing Snapshots

extension UISnapshotTests {
    // MARK: - ActiveRouteChip

    @Suite("ActiveRouteChip Snapshots")
    @MainActor
    struct ActiveRouteChipSnapshotTests {
        private let size = CGSize(width: 200, height: 36)

        // MARK: Local device

        @Test("ActiveRouteChip local light")
        func localLight() {
            let vm = RouteViewModel(initialRoute: .local(name: "MacBook Pro Speakers"))
            let view = ActiveRouteChip(vm: vm)
                .padding(8)
                .frame(width: self.size.width, height: self.size.height)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "route-chip-local-light"
            )
        }

        @Test("ActiveRouteChip local dark")
        func localDark() {
            let vm = RouteViewModel(initialRoute: .local(name: "MacBook Pro Speakers"))
            let view = ActiveRouteChip(vm: vm)
                .padding(8)
                .frame(width: self.size.width, height: self.size.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "route-chip-local-dark"
            )
        }

        // MARK: AirPlay device

        @Test("ActiveRouteChip AirPlay light")
        func airPlayLight() {
            let vm = RouteViewModel(initialRoute: .airPlay(name: "Living Room"))
            let view = ActiveRouteChip(vm: vm)
                .padding(8)
                .frame(width: self.size.width, height: self.size.height)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "route-chip-airplay-light"
            )
        }

        @Test("ActiveRouteChip AirPlay dark")
        func airPlayDark() {
            let vm = RouteViewModel(initialRoute: .airPlay(name: "Living Room"))
            let view = ActiveRouteChip(vm: vm)
                .padding(8)
                .frame(width: self.size.width, height: self.size.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "route-chip-airplay-dark"
            )
        }
    }

    // MARK: - RoutePicker

    /// `AirPlayButton` wraps `AVRoutePickerView`, a system control whose
    /// appearance depends on live HAL state and cannot be snapshotted
    /// deterministically. Only `ActiveRouteChip` is snapshot-tested here;
    /// see the `ActiveRouteChip` suite above. `RoutePicker` tests verify
    /// that the combined layout renders without crashing.
    @Suite("RoutePicker Snapshots")
    @MainActor
    struct RoutePickerSnapshotTests {
        private let size = CGSize(width: 250, height: 36)

        @Test("RoutePicker local light")
        func localLight() {
            let vm = RouteViewModel(initialRoute: .local(name: "MacBook Pro Speakers"))
            let view = RoutePicker(vm: vm)
                .padding(8)
                .frame(width: self.size.width, height: self.size.height)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "route-picker-local-light"
            )
        }

        @Test("RoutePicker local dark")
        func localDark() {
            let vm = RouteViewModel(initialRoute: .local(name: "MacBook Pro Speakers"))
            let view = RoutePicker(vm: vm)
                .padding(8)
                .frame(width: self.size.width, height: self.size.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "route-picker-local-dark"
            )
        }

        @Test("RoutePicker AirPlay light")
        func airPlayLight() {
            let vm = RouteViewModel(initialRoute: .airPlay(name: "Living Room"))
            let view = RoutePicker(vm: vm)
                .padding(8)
                .frame(width: self.size.width, height: self.size.height)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "route-picker-airplay-light"
            )
        }

        @Test("RoutePicker AirPlay dark")
        func airPlayDark() {
            let vm = RouteViewModel(initialRoute: .airPlay(name: "Living Room"))
            let view = RoutePicker(vm: vm)
                .padding(8)
                .frame(width: self.size.width, height: self.size.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "route-picker-airplay-dark"
            )
        }
    }
}
