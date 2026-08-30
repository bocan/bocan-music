import Foundation
import Library

/// Starts the background MusicBrainz artist lookup pass only while the Deep
/// Dive setting is on, and stops it when the setting is turned off (#413).
///
/// The pass sends every artist's MusicBrainz id to musicbrainz.org, so it
/// must never run unasked: with Deep Dive off (the default) the app makes no
/// request the privacy page does not list. Follows the toggle live through
/// `UserDefaults.didChangeNotification`, acting only on an actual flip.
@MainActor
public final class DeepDiveEnrichmentGate {
    private let isEnabled: () -> Bool
    /// Wait before the pass starts: long at launch so scanning settles first,
    /// short when the user flips the toggle, so the progress line moves
    /// within seconds instead of sitting at 0 for the best part of a minute.
    public static let launchDelay: Duration = .seconds(45)
    /// The wait after the user turns the setting on.
    public static let toggleDelay: Duration = .seconds(2)

    private let start: (Duration) -> Void
    private let stop: () -> Void
    private var applied: Bool?
    private var observer: NSObjectProtocol?

    /// Wires the gate to the real service.
    public convenience init(service: ArtistEnrichmentService, defaults: UserDefaults = .standard) {
        self.init(
            isEnabled: { DeepDiveSetting.isEnabled(in: defaults) },
            start: { delay in Task.detached(priority: .background) { await service.start(after: delay) } },
            stop: { Task { await service.stop() } }
        )
    }

    /// Closure form, so tests can count starts and stops.
    public init(isEnabled: @escaping () -> Bool, start: @escaping (Duration) -> Void, stop: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.start = start
        self.stop = stop
        self.observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    /// Starts or stops the pass to match the setting; a no-op when unchanged.
    public func apply() {
        let enabled = self.isEnabled()
        guard enabled != self.applied else { return }
        let wasRunning = self.applied == true
        let delay = self.applied == nil ? Self.launchDelay : Self.toggleDelay
        self.applied = enabled
        if enabled { self.start(delay) } else if wasRunning { self.stop() }
    }
}
