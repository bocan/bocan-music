import Foundation
import Testing
@testable import UI

@Suite("TracksView remove-from-playlist confirmation")
struct TracksViewRemoveFromPlaylistConfirmationTests {
    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "TracksViewRemoveFromPlaylistConfirmationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults suite")
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("confirmation is shown by default")
    func confirmationShownByDefault() {
        let defaults = self.makeUserDefaults()
        #expect(TracksView.shouldConfirmRemoveFromPlaylist(userDefaults: defaults))
    }

    @Test("suppression flag disables confirmation")
    func suppressionFlagDisablesConfirmation() {
        let defaults = self.makeUserDefaults()
        TracksView.setRemoveFromPlaylistConfirmationSuppressed(true, userDefaults: defaults)
        #expect(!TracksView.shouldConfirmRemoveFromPlaylist(userDefaults: defaults))
    }

    @Test("clearing suppression re-enables confirmation")
    func clearingSuppressionReenablesConfirmation() {
        let defaults = self.makeUserDefaults()
        TracksView.setRemoveFromPlaylistConfirmationSuppressed(true, userDefaults: defaults)
        TracksView.setRemoveFromPlaylistConfirmationSuppressed(false, userDefaults: defaults)
        #expect(TracksView.shouldConfirmRemoveFromPlaylist(userDefaults: defaults))
    }
}
