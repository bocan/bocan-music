import Testing

// MARK: - SingleInstanceTests

/// Regression guard: the `DistributedNotificationCenter` name used by
/// `SingleInstance` must never change without a coordinated update — any
/// installed copy that still broadcasts the old name would fail to activate
/// a new-version instance, breaking the single-instance guarantee.
@Suite("SingleInstance")
struct SingleInstanceTests {
    /// Verify the activation-notification name hasn't drifted from the
    /// registered value.  If this fails, update `App/SingleInstance.swift`
    /// **and** any external tools / scripts that monitor this notification.
    @Test("activation notification name is stable")
    func activationNotificationNameIsStable() {
        #expect(SingleInstance.activationNotification == "io.cloudcauldron.bocan.activate")
    }
}
