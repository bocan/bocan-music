import AudioEngine
import Foundation
import Testing
@testable import UI

// MARK: - DSPViewModelTests

@Suite("DSPViewModel")
@MainActor
struct DSPViewModelTests {
    // MARK: - isEQActive

    @Test("isEQActive is false when EQ is disabled")
    func isEQActiveFalseWhenDisabled() {
        let vm = DSPViewModel(engine: AudioEngine())
        vm.state.eqEnabled = false
        vm.state.eqPresetID = BuiltInPresets.rock.id
        #expect(vm.isEQActive == false)
    }

    @Test("isEQActive is false when EQ is enabled but preset is Flat")
    func isEQActiveFalseWhenFlat() {
        let vm = DSPViewModel(engine: AudioEngine())
        vm.state.eqEnabled = true
        vm.state.eqPresetID = BuiltInPresets.flat.id
        #expect(vm.isEQActive == false)
    }

    @Test("isEQActive is false when EQ is enabled but no preset is selected")
    func isEQActiveFalseWhenNilPreset() {
        let vm = DSPViewModel(engine: AudioEngine())
        vm.state.eqEnabled = true
        vm.state.eqPresetID = nil
        #expect(vm.isEQActive == false)
    }

    @Test("isEQActive is true when EQ is enabled and a non-flat preset is active")
    func isEQActiveTrueWhenNonFlat() {
        let vm = DSPViewModel(engine: AudioEngine())
        vm.state.eqEnabled = true
        vm.state.eqPresetID = BuiltInPresets.rock.id
        #expect(vm.isEQActive == true)
    }

    @Test("isEQActive reacts to eqEnabled toggle")
    func isEQActiveReflectsToggle() {
        let vm = DSPViewModel(engine: AudioEngine())
        vm.state.eqEnabled = true
        vm.state.eqPresetID = BuiltInPresets.jazz.id
        #expect(vm.isEQActive == true)

        vm.state.eqEnabled = false
        #expect(vm.isEQActive == false)
    }

    @Test("isEQActive reacts to preset change back to Flat")
    func isEQActiveFalseAfterRevertToFlat() {
        let vm = DSPViewModel(engine: AudioEngine())
        vm.state.eqEnabled = true
        vm.state.eqPresetID = BuiltInPresets.rock.id
        #expect(vm.isEQActive == true)

        vm.state.eqPresetID = BuiltInPresets.flat.id
        #expect(vm.isEQActive == false)
    }
}
