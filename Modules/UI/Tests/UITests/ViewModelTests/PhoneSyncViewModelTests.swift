import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - Fake control seam (shared with the snapshot tests)

/// A configurable, call-recording `PhoneSyncControlling` for view-model and
/// snapshot tests. No real server, no network.
final class FakePhoneSyncControl: PhoneSyncControlling, @unchecked Sendable {
    var enabled: Bool
    var profile: PhoneSyncProfile
    var playlists: [PhoneSyncPlaylist]
    var estimate: PhoneSyncSizeEstimate
    var devices: [TrustedDevice]

    private(set) var setEnabledCalls: [Bool] = []
    private(set) var savedProfiles: [PhoneSyncProfile] = []
    private(set) var revoked: [String] = []
    private(set) var armCount = 0
    private(set) var cancelCount = 0

    init(
        enabled: Bool = false,
        profile: PhoneSyncProfile = .everything,
        playlists: [PhoneSyncPlaylist] = [],
        estimate: PhoneSyncSizeEstimate = .zero,
        devices: [TrustedDevice] = []
    ) {
        self.enabled = enabled
        self.profile = profile
        self.playlists = playlists
        self.estimate = estimate
        self.devices = devices
    }

    func isEnabled() -> Bool {
        self.enabled
    }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        self.setEnabledCalls.append(enabled)
    }

    func loadProfile() async -> PhoneSyncProfile {
        self.profile
    }

    func saveProfile(_ profile: PhoneSyncProfile) async {
        self.profile = profile
        self.savedProfiles.append(profile)
    }

    func availablePlaylists() async -> [PhoneSyncPlaylist] {
        self.playlists
    }

    func sizeEstimate(for _: PhoneSyncProfile) async -> PhoneSyncSizeEstimate {
        self.estimate
    }

    func pairedDevices() async -> [TrustedDevice] {
        self.devices
    }

    func revoke(fingerprint: String) async {
        self.revoked.append(fingerprint)
        self.devices.removeAll { $0.fingerprint == fingerprint }
    }

    func armPairing() async {
        self.armCount += 1
    }

    func cancelPairing() async {
        self.cancelCount += 1
    }
}

func fakeDevice(_ name: String, fingerprint: String) -> TrustedDevice {
    TrustedDevice(fingerprint: fingerprint, certDER: Data([0x01]), deviceName: name, pairedAt: 1_700_000_000)
}

// MARK: - PhoneSyncViewModelTests

@MainActor
@Suite("PhoneSyncViewModel")
struct PhoneSyncViewModelTests {
    /// Yields until `condition` holds or a bounded number of turns elapse, so a
    /// same-actor child task can reach its next suspension point.
    private func settle(until condition: () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            await Task.yield()
        }
    }

    @Test("load hydrates the toggle, profile, playlists, estimate, and devices")
    func loadHydrates() async {
        let control = FakePhoneSyncControl(
            enabled: true,
            profile: PhoneSyncProfile(mode: .choosePlaylists, selectedPlaylistIDs: [2], includePodcasts: false),
            playlists: [PhoneSyncPlaylist(id: 2, name: "Chill")],
            estimate: PhoneSyncSizeEstimate(bytes: 1_000_000, trackCount: 3, episodeCount: 1),
            devices: [fakeDevice("Pixel", fingerprint: "aa")]
        )
        let vm = PhoneSyncViewModel(control: control)
        await vm.load()

        #expect(vm.enabled)
        #expect(vm.profile.mode == .choosePlaylists)
        #expect(vm.profile.selectedPlaylistIDs == [2])
        #expect(vm.playlists.count == 1)
        #expect(vm.sizeEstimate.trackCount == 3)
        #expect(vm.pairedDevices.count == 1)
    }

    @Test("toggling enabled calls through to the seam")
    func toggleEnabled() async {
        let control = FakePhoneSyncControl()
        let vm = PhoneSyncViewModel(control: control)
        await vm.setEnabled(true)
        #expect(vm.enabled)
        #expect(control.setEnabledCalls == [true])
        await vm.setEnabled(false)
        #expect(control.setEnabledCalls == [true, false])
    }

    @Test("editing the profile writes through and recomputes the estimate")
    func editProfile() async {
        let control = FakePhoneSyncControl(
            playlists: [PhoneSyncPlaylist(id: 5, name: "Road Trip")],
            estimate: PhoneSyncSizeEstimate(bytes: 42, trackCount: 2, episodeCount: 0)
        )
        let vm = PhoneSyncViewModel(control: control)
        await vm.load()

        await vm.setMode(.choosePlaylists)
        #expect(vm.profile.mode == .choosePlaylists)
        await vm.togglePlaylist(5)
        #expect(vm.isPlaylistSelected(5))
        await vm.setIncludePodcasts(false)
        #expect(!vm.profile.includePodcasts)

        // Three edits each persisted through the seam.
        #expect(control.savedProfiles.count == 3)
        #expect(control.savedProfiles.last?.selectedPlaylistIDs == [5])
        #expect(vm.sizeEstimate.trackCount == 2)

        await vm.togglePlaylist(5)
        #expect(!vm.isPlaylistSelected(5))
    }

    @Test("revoke removes the device row")
    func revoke() async {
        let control = FakePhoneSyncControl(devices: [
            fakeDevice("Pixel", fingerprint: "aa"),
            fakeDevice("Nexus", fingerprint: "bb"),
        ])
        let vm = PhoneSyncViewModel(control: control)
        await vm.load()
        #expect(vm.pairedDevices.count == 2)

        await vm.revoke(fakeDevice("Pixel", fingerprint: "aa"))
        #expect(control.revoked == ["aa"])
        #expect(vm.pairedDevices.map(\.fingerprint) == ["bb"])
    }

    @Test("startPairing arms and presents the waiting state")
    func startPairing() async {
        let control = FakePhoneSyncControl()
        let vm = PhoneSyncViewModel(control: control)
        await vm.startPairing()
        #expect(vm.pairingSheet == .waiting)
        #expect(control.armCount == 1)
    }

    @Test("the pairing callbacks move the sheet through its states")
    func pairingFlow() async {
        let control = FakePhoneSyncControl(devices: [fakeDevice("Pixel", fingerprint: "aa")])
        let vm = PhoneSyncViewModel(control: control)
        await vm.startPairing()

        await vm.pairingPresentCode("123456")
        #expect(vm.pairingSheet == .code("123456"))

        async let trusted = vm.pairingRequestConfirmation(deviceName: "Pixel", fingerprintTail: "abcd1234")
        await self.settle { vm.pairingSheet == .confirm(deviceName: "Pixel", fingerprintTail: "abcd1234") }
        #expect(vm.pairingSheet == .confirm(deviceName: "Pixel", fingerprintTail: "abcd1234"))
        vm.confirmTrust(true)
        #expect(await trusted)

        await vm.pairingFinished(.paired(deviceName: "Pixel"))
        #expect(vm.pairingSheet == .result(.paired(deviceName: "Pixel")))
    }

    @Test("declining confirmation returns false")
    func declineConfirmation() async {
        let control = FakePhoneSyncControl()
        let vm = PhoneSyncViewModel(control: control)

        async let trusted = vm.pairingRequestConfirmation(deviceName: "Pixel", fingerprintTail: "abcd1234")
        await self.settle { vm.pairingSheet != nil }
        vm.confirmTrust(false)
        #expect(await trusted == false)
    }

    @Test("dismissing cancels pairing and clears the sheet")
    func dismiss() async {
        let control = FakePhoneSyncControl()
        let vm = PhoneSyncViewModel(control: control)
        await vm.startPairing()
        await vm.dismissPairing()
        #expect(vm.pairingSheet == nil)
        #expect(control.cancelCount == 1)
    }
}
