import AppKit
import AudioEngine
import Observability
import SwiftUI

// MARK: - Notification

/// Notification names posted by Bòcan for cross-component coordination.
public extension Notification.Name {
    /// Posted to open the audio-output device menu (Playback menu item / ⌘⇧U).
    /// `OutputDeviceButton`'s coordinator observes this and pops the menu.
    /// Post from the main thread only.
    static let bocanActivateRoutePicker = Notification.Name("io.cloudcauldron.bocan.activateRoutePicker")
}

// MARK: - OutputDeviceButton

/// A toolbar button that pops a menu of CoreAudio output devices and routes
/// **only this app's** audio to the chosen one (AirPlay receivers included),
/// leaving the rest of the system on its own output.
///
/// Replaces the old `AVRoutePickerView`, which can only redirect `AVPlayer`
/// playback and never moved this app's `AVAudioEngine` output. The device list
/// is rebuilt on every open so receivers that appear/disappear stay current.
public struct OutputDeviceButton: NSViewRepresentable {
    private let vm: RouteViewModel

    public init(vm: RouteViewModel) {
        self.vm = vm
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(vm: self.vm)
    }

    public func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "Audio output")
        button.contentTintColor = .controlAccentColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.toolTip = "Choose audio output device"
        button.setAccessibilityLabel("Choose audio output device")
        context.coordinator.attach(to: button)
        return button
    }

    public func updateNSView(_: NSButton, context: Context) {
        context.coordinator.vm = self.vm
    }

    // MARK: - Coordinator

    /// Builds and presents the device `NSMenu`, and forwards selections to the
    /// view model. `@MainActor` because it is all AppKit.
    @MainActor
    public final class Coordinator: NSObject {
        var vm: RouteViewModel
        private let log = AppLogger.make(.cast)
        private weak var button: NSButton?
        /// See AirPlayButton's note: the opaque observer token isn't Sendable; it
        /// is written once on the main actor and read only in the nonisolated deinit.
        private nonisolated(unsafe) var observer: NSObjectProtocol?

        init(vm: RouteViewModel) {
            self.vm = vm
            super.init()
        }

        func attach(to button: NSButton) {
            self.button = button
            self.observer = NotificationCenter.default.addObserver(
                forName: .bocanActivateRoutePicker,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.present() }
            }
        }

        @objc func showMenu(_: NSButton) {
            self.present()
        }

        private func present() {
            guard let button = self.button else {
                self.log.warning("cast.deviceMenu.present.noButton")
                return
            }
            let devices = self.vm.availableDevices()
            self.log.info("cast.deviceMenu.present", ["count": devices.count])

            let menu = NSMenu()
            let defaultItem = NSMenuItem(
                title: "System Default",
                action: #selector(self.selectSystemDefault),
                keyEquivalent: ""
            )
            defaultItem.target = self
            defaultItem.state = self.vm.selectedDeviceID == nil ? .on : .off
            menu.addItem(defaultItem)
            menu.addItem(.separator())

            for device in devices {
                let item = NSMenuItem(
                    title: device.name,
                    action: #selector(self.selectDevice(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = DeviceBox(device)
                item.state = self.vm.selectedDeviceID == device.id ? .on : .off
                menu.addItem(item)
            }

            // Drop the menu just below the button.
            let origin = NSPoint(x: 0, y: button.bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: button)
        }

        @objc private func selectSystemDefault() {
            self.vm.selectDevice(nil)
        }

        @objc private func selectDevice(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? DeviceBox else { return }
            self.vm.selectDevice(box.device)
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// MARK: - DeviceBox

/// Boxes a `DeviceInfo` value so it can ride in an `NSMenuItem.representedObject`
/// (which requires a reference type across the Obj-C boundary).
private final class DeviceBox {
    let device: DeviceInfo

    init(_ device: DeviceInfo) {
        self.device = device
    }
}
