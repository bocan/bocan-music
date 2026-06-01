import Playback
import Testing
@testable import AudioEngine
@testable import UI

// MARK: - RouteViewModelTests

@Suite("RouteViewModel device selection")
@MainActor
struct RouteViewModelTests {
    @Test("selecting a device pins it and reflects it on the chip")
    func selectDevicePins() {
        let vm = RouteViewModel(initialRoute: .local(name: "MacBook Pro Speakers"))
        let device = DeviceInfo(id: 42, name: "Living Room", uid: "uid-42")

        vm.selectDevice(device)

        #expect(vm.selectedDeviceID == 42)
        #expect(vm.current.displayName == "Living Room")
    }

    @Test("selecting System Default clears the pin")
    func selectSystemDefaultClearsPin() {
        let vm = RouteViewModel(initialRoute: .local(name: "MacBook Pro Speakers"))
        vm.selectDevice(DeviceInfo(id: 7, name: "USB DAC", uid: "uid-7"))
        #expect(vm.selectedDeviceID == 7)

        vm.selectDevice(nil)

        #expect(vm.selectedDeviceID == nil)
    }
}
