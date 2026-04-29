# Phase 15 — AirPlay routing

> Prerequisites: Phases 0–14 complete. AudioEngine survives system output device changes.
>
> Read `phases/_standards.md` first.

## Goal

Surface AirPlay 2 as a first-class route through the system picker, and let Bòcan
*know* what device audio is currently coming out of so the UI can say
"Playing on Living Room HomePod". Audio follows the system output device — that's
how AirPlay on macOS works for non-system apps — and Bòcan just gives the user a
discoverable entry point and a clear indicator.

## Non-goals

- **Google Cast.** Officially excluded. Google does not ship a maintained macOS
  Cast SDK and a native CASTV2 implementation is out of scope.
- **Sonos / DLNA / generic UPnP rendering.**
- **Multi-room grouping** — managed at the OS level (System Settings ▸ Sound /
  the AirPlay menu in Control Centre).
- **Video casting.** Audio only.
- **An embedded HTTP media server.** Not needed without Cast.

## Outcome shape

```
Modules/Playback/Sources/Playback/Routing/
├── Route.swift                        # Enum + metadata
├── OutputDeviceProvider.swift         # Protocol + CoreAudio HAL implementation
└── RouteManager.swift                 # Actor publishing the current Route

Modules/UI/Sources/UI/Routing/
├── AirPlayButton.swift                # AVRoutePickerView wrapped for SwiftUI
├── ActiveRouteChip.swift              # Transport-strip indicator
├── RoutePicker.swift                  # AirPlay button + chip combined
└── RouteViewModel.swift               # @MainActor consumer of RouteManager
```

## Implementation plan

### Route model

1. `Route` is a Swift enum with three cases:
   ```swift
   public enum Route: Sendable, Hashable, Identifiable {
       case local(name: String)              // built-in speakers / headphones
       case airPlay(name: String)            // AirPlay-routed device
       case external(name: String, kind: String)
                                              // Bluetooth, HDMI, USB DAC, etc.
   }
   ```
   `Route.id` derives a stable string for SwiftUI identity.

2. `OutputDeviceInfo` is a value type returned by the provider; carries the
   CoreAudio device ID, the human-readable name, and a transport-type tag
   so `RouteManager` can categorise it as `local` / `airPlay` / `external`.

### Discovery & observation

3. **`OutputDeviceProvider`** is a protocol so tests can inject a mock:
   ```swift
   public protocol OutputDeviceProvider: Sendable {
       func current() async -> OutputDeviceInfo
       func updates() -> AsyncStream<OutputDeviceInfo>
   }
   ```

4. **`CoreAudioOutputDeviceProvider`** is the production implementation. It
   listens to `kAudioHardwarePropertyDefaultOutputDevice` on the system
   object via `AudioObjectAddPropertyListenerBlock`, plus
   `kAudioObjectPropertyName` and `kAudioDevicePropertyTransportType` on the
   *current* default device. On every change it emits a fresh
   `OutputDeviceInfo` to subscribers.

5. **`RouteManager`** is an actor:
   - Owns the provider's `updates()` stream and re-broadcasts `Route` values.
   - Exposes `current` (read) and `routes` (`AsyncStream<Route>`).
   - Maps transport types to cases: `.airPlay` for `kAudioDeviceTransportTypeAirPlay`,
     `.local` for built-in, `.external` for everything else (with a kind
     label like "Bluetooth", "HDMI", "USB").

### UI

6. **`AirPlayButton`** is an `NSViewRepresentable` around `AVRoutePickerView`
   (AVKit). Tapping it opens the system AirPlay picker; the system handles
   routing. Styled to match the transport strip (button look, accessible label).

7. **`ActiveRouteChip`** is a small SwiftUI view next to the transport that
   reads from `RouteViewModel` and shows the current device name with an
   appropriate SF Symbol (`hifispeaker.fill` for AirPlay, `airpods` /
   `headphones` / `speaker.fill` otherwise).

8. **`RoutePicker`** combines the two: chip on the left, AirPlay button on
   the right. Drop it into `NowPlayingStrip`.

9. **`RouteViewModel`** is `@MainActor`, owns a `Task` that consumes
   `RouteManager.routes`, and publishes `current` for the views.

### Wiring

10. Construct `RouteManager` once in `BocanApp.init()` with the production
    `CoreAudioOutputDeviceProvider`. Build a `RouteViewModel` and inject it
    into the SwiftUI environment.

11. The audio engine itself does **not** need new code — `AVAudioEngine`
    automatically follows the system default output device, including
    AirPlay. `EngineGraph` already handles `AVAudioEngineConfigurationChange`
    notifications from earlier phases.

### Privacy & entitlements

12. **Nothing new.** AirPlay routing on macOS goes through the system audio
    stack; there is no LAN traffic from the app, no Bonjour discovery in
    process, and no embedded HTTP server. Existing entitlements suffice.

## Definitions & contracts

### `Route`

```swift
public enum Route: Sendable, Hashable, Identifiable {
    case local(name: String)
    case airPlay(name: String)
    case external(name: String, kind: String)

    public var id: String { ... }
    public var displayName: String { ... }
    public var iconSystemName: String { ... }
}
```

### `RouteManager`

```swift
public actor RouteManager {
    public init(provider: any OutputDeviceProvider)
    public var current: Route { get async }
    public nonisolated func routes() -> AsyncStream<Route>
    public func start() async
    public func stop() async
}
```

## Context7 lookups

- `use context7 AVRoutePickerView macOS NSViewRepresentable`
- `use context7 CoreAudio HAL kAudioHardwarePropertyDefaultOutputDevice listener Swift`
- `use context7 CoreAudio kAudioDevicePropertyTransportType airplay`
- `use context7 AVAudioEngine configuration change notification Swift`

## Dependencies

None new.

## Test plan

### Unit (covered by CI)

- **`Route`**: every case round-trips its `id`, `displayName`, and
  `iconSystemName`; equality is structural.
- **`RouteManager`** with a `MockOutputDeviceProvider`:
  - Initial `current` matches the provider's seed value.
  - Pushing a new device through the mock stream produces a corresponding
    `Route` on the manager's stream.
  - `airPlay` transport tags map to `.airPlay`; built-in to `.local`;
    everything else to `.external` with the correct kind label.
  - `start()` is idempotent; `stop()` cancels the consumer task.
- **Route ID stability**: same case + same name → same id; different name →
  different id.

### Manual / integration

- Open Bòcan, click the AirPlay button → system picker appears.
- Pick an AirPlay 2 speaker → audio plays on it; the chip updates to its
  name within ~1 s.
- Switch back to built-in via the system picker → chip updates without
  needing app focus.
- Switch via Control Centre's AirPlay menu (not Bòcan's button) → chip
  still updates (HAL listener fires regardless of the source of the change).
- Plug headphones in → chip updates to "Headphones".

## Acceptance criteria

- [ ] AirPlay button opens the system picker.
- [ ] Active route chip reflects the current output device and updates
      automatically when it changes.
- [ ] AirPlay 2 device selection plays audio without changes to the engine
      graph (works because AVAudioEngine follows system output).
- [ ] No new entitlements required; existing sandbox unchanged.
- [ ] 80 %+ coverage on `Route` and `RouteManager`.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **macOS AirPlay is system-routed.** Apps don't enumerate AirPlay devices
  themselves — the system picker does it. We just observe the *current*
  output device and trust the system.
- **HAL property listeners** fire on a CoreAudio-owned thread. Hop to the
  actor before mutating state. Use `AudioObjectAddPropertyListenerBlock`
  rather than the C-callback variant so we get a closure with proper
  capture semantics.
- **Aggregate devices** can show up as the default output (Loopback,
  BlackHole). Treat as `.external` with kind "Aggregate".
- **AirPlay 2 latency** can be in the hundreds of milliseconds.
- **`AVRoutePickerView` styling**: it's an AppKit control; don't try to
  colour-tint it. Treat the picker button as an opaque system control.
- **Headphone hot-plug**: macOS swaps the default output in ~50 ms; the
  HAL listener fires and we re-publish.

## Handoff

Phase 16 (Distribution) inherits no extra entitlements from this phase.
