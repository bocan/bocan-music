import AppKit
import Persistence
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

extension UISnapshotTests {
    // MARK: - PhoneSync pane + pairing sheet snapshots

    @Suite("PhoneSync Snapshots")
    @MainActor
    struct PhoneSyncSnapshotTests {
        private let paneSize = CGSize(width: 720, height: 620)
        private let sheetSize = CGSize(width: 380, height: 470)

        private func pane(_ control: FakePhoneSyncControl) async -> PhoneSyncViewModel {
            let vm = PhoneSyncViewModel(control: control)
            await vm.load()
            return vm
        }

        private func assertPane(_ vm: PhoneSyncViewModel, dark: Bool, named: String) {
            let view = PhoneSyncSettingsView(viewModel: vm)
                .frame(width: self.paneSize.width, height: self.paneSize.height)
                .colorScheme(dark ? .dark : .light)
            assertSnapshot(
                of: host(view, size: self.paneSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: named
            )
        }

        private func assertSheet(_ state: PairingSheetState, dark: Bool, named: String) {
            let vm = PhoneSyncViewModel(control: FakePhoneSyncControl())
            vm.pairingSheet = state
            // Sheets get their window background from the presentation chrome; in
            // isolation we supply it so dark-mode text isn't white-on-transparent.
            let view = PhoneSyncPairingSheet(viewModel: vm)
                .frame(width: self.sheetSize.width, height: self.sheetSize.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .colorScheme(dark ? .dark : .light)
            assertSnapshot(
                of: host(view, size: self.sheetSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: named
            )
        }

        // MARK: Fixtures

        private var enabledEverything: FakePhoneSyncControl {
            FakePhoneSyncControl(
                enabled: true,
                profile: .everything,
                estimate: PhoneSyncSizeEstimate(bytes: 13_314_398_617, trackCount: 1203, episodeCount: 0)
            )
        }

        private var enabledChoose: FakePhoneSyncControl {
            FakePhoneSyncControl(
                enabled: true,
                profile: PhoneSyncProfile(mode: .choosePlaylists, selectedPlaylistIDs: [1, 3], includePodcasts: true),
                playlists: [
                    PhoneSyncPlaylist(id: 1, name: "Road Trip"),
                    PhoneSyncPlaylist(id: 2, name: "Focus"),
                    PhoneSyncPlaylist(id: 3, name: "Dinner Party"),
                ],
                estimate: PhoneSyncSizeEstimate(bytes: 2_400_000_000, trackCount: 214, episodeCount: 6)
            )
        }

        private var enabledWithDevices: FakePhoneSyncControl {
            FakePhoneSyncControl(
                enabled: true,
                profile: .everything,
                estimate: PhoneSyncSizeEstimate(bytes: 13_314_398_617, trackCount: 1203, episodeCount: 0),
                devices: [
                    fakeDevice("Pixel 8", fingerprint: "aa11bb22"),
                    fakeDevice("Chris's Phone", fingerprint: "cc33dd44"),
                ]
            )
        }

        // MARK: Pane

        @Test("pane disabled light") func paneDisabledLight() async {
            await self.assertPane(self.pane(FakePhoneSyncControl(enabled: false)), dark: false, named: "phonesync-pane-disabled-light")
        }

        @Test("pane disabled dark") func paneDisabledDark() async {
            await self.assertPane(self.pane(FakePhoneSyncControl(enabled: false)), dark: true, named: "phonesync-pane-disabled-dark")
        }

        @Test("pane everything light") func paneEverythingLight() async {
            await self.assertPane(self.pane(self.enabledEverything), dark: false, named: "phonesync-pane-everything-light")
        }

        @Test("pane everything dark") func paneEverythingDark() async {
            await self.assertPane(self.pane(self.enabledEverything), dark: true, named: "phonesync-pane-everything-dark")
        }

        @Test("pane choose playlists light") func paneChooseLight() async {
            await self.assertPane(self.pane(self.enabledChoose), dark: false, named: "phonesync-pane-choose-light")
        }

        @Test("pane choose playlists dark") func paneChooseDark() async {
            await self.assertPane(self.pane(self.enabledChoose), dark: true, named: "phonesync-pane-choose-dark")
        }

        @Test("pane with paired devices light") func paneDevicesLight() async {
            await self.assertPane(self.pane(self.enabledWithDevices), dark: false, named: "phonesync-pane-devices-light")
        }

        @Test("pane with paired devices dark") func paneDevicesDark() async {
            await self.assertPane(self.pane(self.enabledWithDevices), dark: true, named: "phonesync-pane-devices-dark")
        }

        // MARK: Sheet

        @Test("sheet waiting light") func sheetWaitingLight() {
            self.assertSheet(.waiting, dark: false, named: "phonesync-sheet-waiting-light")
        }

        @Test("sheet waiting dark") func sheetWaitingDark() {
            self.assertSheet(.waiting, dark: true, named: "phonesync-sheet-waiting-dark")
        }

        @Test("sheet code light") func sheetCodeLight() {
            self.assertSheet(.code("123456"), dark: false, named: "phonesync-sheet-code-light")
        }

        @Test("sheet code dark") func sheetCodeDark() {
            self.assertSheet(.code("123456"), dark: true, named: "phonesync-sheet-code-dark")
        }

        @Test("sheet confirm light") func sheetConfirmLight() {
            self.assertSheet(
                .confirm(deviceName: "Pixel 8", fingerprintTail: "cc33dd44"),
                dark: false,
                named: "phonesync-sheet-confirm-light"
            )
        }

        @Test("sheet confirm dark") func sheetConfirmDark() {
            self.assertSheet(
                .confirm(deviceName: "Pixel 8", fingerprintTail: "cc33dd44"),
                dark: true,
                named: "phonesync-sheet-confirm-dark"
            )
        }

        @Test("sheet result success light") func sheetResultSuccessLight() {
            self.assertSheet(.result(.paired(deviceName: "Pixel 8")), dark: false, named: "phonesync-sheet-result-success-light")
        }

        @Test("sheet result success dark") func sheetResultSuccessDark() {
            self.assertSheet(.result(.paired(deviceName: "Pixel 8")), dark: true, named: "phonesync-sheet-result-success-dark")
        }

        @Test("sheet result failure light") func sheetResultFailureLight() {
            self.assertSheet(.result(.codeMismatch), dark: false, named: "phonesync-sheet-result-failure-light")
        }

        @Test("sheet result failure dark") func sheetResultFailureDark() {
            self.assertSheet(.result(.codeMismatch), dark: true, named: "phonesync-sheet-result-failure-dark")
        }
    }
}
