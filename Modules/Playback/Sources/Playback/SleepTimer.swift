import Foundation
import Observability

// MARK: - SleepTimerPreset

/// A user-selectable duration preset for the sleep timer.
public enum SleepTimerPreset: Sendable, Equatable, CaseIterable, Codable {
    case off
    case minutes15
    case minutes30
    case minutes45
    case minutes60
    case minutes90
    case minutes120
    case custom(minutes: Int)

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .minutes15: "15 min"
        case .minutes30: "30 min"
        case .minutes45: "45 min"
        case .minutes60: "1 hr"
        case .minutes90: "1 hr 30 min"
        case .minutes120: "2 hr"
        case let .custom(m): "\(m) min"
        }
    }

    public var minutes: Int? {
        switch self {
        case .off: nil
        case .minutes15: 15
        case .minutes30: 30
        case .minutes45: 45
        case .minutes60: 60
        case .minutes90: 90
        case .minutes120: 120
        case let .custom(m): m
        }
    }

    public static let allCases: [SleepTimerPreset] = [
        .off, .minutes15, .minutes30, .minutes45, .minutes60, .minutes90, .minutes120,
    ]
}

// MARK: - SleepTimer

/// Countdown actor that fires a stop command when the configured duration elapses.
///
/// **Persistence**: on set, writes `expiresAt` to `UserDefaults`
/// (`playback.sleepTimer.expiresAt`) so the timer survives an app relaunch.
/// On wake from system sleep, call `handleSystemWake()` to immediately stop
/// playback if the deadline already passed.
///
/// **Fade-out**: when `fadeOut` is `true`, the timer ramps the playback volume
/// from 1.0 → 0 over the final 30 seconds before stopping.
public actor SleepTimer {
    // MARK: - Types

    public typealias StopAction = @Sendable () async -> Void
    public typealias SetVolumeAction = @Sendable (Float) async -> Void

    // MARK: - Public state

    /// Seconds remaining until stop, or `nil` when the timer is off.
    public private(set) var remaining: TimeInterval?

    /// Whether the "fade out in last 30 s" option is active.
    public private(set) var fadeOut = false

    // MARK: - Private

    private let log = AppLogger.make(.playback)
    private var expiresAt: Date?
    private var countdownTask: Task<Void, Never>?
    private let onStop: StopAction
    private let onSetVolume: SetVolumeAction

    private static let defaultsKeyExpires = "playback.sleepTimer.expiresAt"
    private static let defaultsKeyFadeOut = "playback.sleepTimer.fadeOut"
    private static let fadeDuration: TimeInterval = 30

    // MARK: - Init

    public init(onStop: @escaping StopAction, onSetVolume: @escaping SetVolumeAction) {
        self.onStop = onStop
        self.onSetVolume = onSetVolume
    }

    // MARK: - Public API

    /// Schedule a sleep timer for `minutes` minutes from now.
    /// Pass `nil` to cancel. `fadeOut` controls the 30 s volume ramp.
    public func set(minutes: Int?, fadeOut: Bool = false) {
        self.cancel()
        guard let minutes, minutes > 0 else {
            self.remaining = nil
            self.fadeOut = false
            self.persistState(expiresAt: nil, fadeOut: false)
            self.log.debug("sleepTimer.cancelled")
            return
        }

        let expires = Date(timeIntervalSinceNow: TimeInterval(minutes * 60))
        self.expiresAt = expires
        self.fadeOut = fadeOut
        self.remaining = TimeInterval(minutes * 60)
        self.persistState(expiresAt: expires, fadeOut: fadeOut)
        self.log.debug("sleepTimer.set", ["minutes": minutes, "fadeOut": fadeOut])
        self.startCountdown(expiresAt: expires)
    }

    /// Call when the app wakes from system sleep.  If the deadline already
    /// passed while the Mac was asleep, stop playback immediately.
    public func handleSystemWake() {
        guard let expires = self.expiresAt else { return }
        if expires <= Date() {
            self.log.debug("sleepTimer.wakeExpired")
            self.fire()
        }
    }

    /// Restore persisted timer state after a relaunch.
    /// Call once during app init; this resumes the countdown if still valid.
    public func restoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard let expires = defaults.object(forKey: Self.defaultsKeyExpires) as? Date else { return }
        let fadeOut = defaults.bool(forKey: Self.defaultsKeyFadeOut)
        let remaining = expires.timeIntervalSinceNow
        guard remaining > 0 else {
            // Timer already expired while app was closed — clear persisted state.
            self.persistState(expiresAt: nil, fadeOut: false)
            return
        }
        self.log.debug("sleepTimer.restored", ["remainingSeconds": remaining])
        self.expiresAt = expires
        self.fadeOut = fadeOut
        self.remaining = remaining
        self.startCountdown(expiresAt: expires)
    }

    // MARK: - Private

    private func cancel() {
        self.countdownTask?.cancel()
        self.countdownTask = nil
        self.expiresAt = nil
    }

    private func startCountdown(expiresAt: Date) {
        self.countdownTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let now = Date()
                let left = expiresAt.timeIntervalSince(now)
                if left <= 0 {
                    await self.fire()
                    return
                }
                await self.tick(remaining: left, expiresAt: expiresAt)
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s tick
            }
        }
    }

    private func tick(remaining: TimeInterval, expiresAt: Date) async {
        self.remaining = remaining

        guard self.fadeOut, remaining <= Self.fadeDuration else { return }
        // Volume ramp: 0 at expiry, proportional before that.
        let fraction = Float(remaining / Self.fadeDuration)
        await self.onSetVolume(fraction)
    }

    private func fire() {
        self.log.debug("sleepTimer.fired")
        self.cancel()
        self.remaining = nil
        self.fadeOut = false
        self.persistState(expiresAt: nil, fadeOut: false)
        Task { await self.onStop() }
    }

    private func persistState(expiresAt: Date?, fadeOut: Bool) {
        let defaults = UserDefaults.standard
        if let expiresAt {
            defaults.set(expiresAt, forKey: Self.defaultsKeyExpires)
            defaults.set(fadeOut, forKey: Self.defaultsKeyFadeOut)
        } else {
            defaults.removeObject(forKey: Self.defaultsKeyExpires)
            defaults.removeObject(forKey: Self.defaultsKeyFadeOut)
        }
    }
}
