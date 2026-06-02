import Playback
import Testing
@testable import AudioEngine
@testable import UI

// MARK: - RouteViewModelTests

@Suite("RouteViewModel device menu")
@MainActor
struct RouteViewModelTests {
    @Test("availableDevices returns the CoreAudio output devices")
    func availableDevicesEnumerates() {
        let vm = RouteViewModel(initialRoute: .local(name: "MacBook Pro Speakers"))
        // On a host with no audio devices this is empty; the contract is only
        // that it matches the DeviceRouter enumeration without crashing.
        #expect(vm.availableDevices().map(\.id) == DeviceRouter.outputDevices().map(\.id))
    }

    @Test("currentDefaultDeviceID matches the HAL default output device")
    func currentDefaultMatchesHAL() {
        let vm = RouteViewModel(initialRoute: .local(name: "MacBook Pro Speakers"))
        #expect(vm.currentDefaultDeviceID() == DeviceRouter.defaultOutputDevice()?.id)
    }
}
