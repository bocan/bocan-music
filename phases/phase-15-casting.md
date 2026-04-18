# Phase 15 — Casting (AirPlay 2 + Google Cast)

> Prerequisites: Phases 0–14 complete. AudioEngine supports routing changes.
>
> Read `phases/_standards.md` first.

## Goal

Play Bòcan through remote speakers. AirPlay 2 first-class via the system picker. Google Cast via the official SDK. Transparent route switching: press play anywhere, pick a device, audio continues without losing position. Volume sync with remote. Graceful degradation when remote fails (auto-return to local).

## Non-goals

- Sonos via UPnP — not in v1 (would need custom protocol work). Noted as a future phase.
- Multi-room grouping control from the app — use the system (AirPlay groups via macOS Sound menu; Google Home for Cast groups). We just pick the device.
- DLNA / generic UPnP rendering — no.
- Video casting — no.

## Outcome shape

```
Modules/Playback/Sources/Playback/Routing/
├── RouteManager.swift                 # Actor coordinating route switches
├── Route.swift                        # Enum + metadata
├── LocalRoute.swift                   # Default AVAudioEngine route
├── AirPlayRoute.swift                 # System route via AVAudioSession-equivalent
└── CastRoute.swift                    # Google Cast adapter

Modules/Playback/Sources/Playback/Cast/
├── CastDiscovery.swift                # GCKCastContext wrapper
├── CastSession.swift                  # GCKSession lifecycle
├── CastMediaServer.swift              # Local HTTP server to serve track bytes
└── CastMediaItemBuilder.swift         # Builds GCKMediaInformation with metadata + cover URL

Modules/UI/Sources/UI/Routing/
├── RoutePicker.swift                  # Single control: AirPlay + Cast unified
├── AirPlayButton.swift                # AVRoutePickerView wrapped for SwiftUI
├── CastButton.swift                   # GCKUICastButton wrapped
└── ActiveRouteChip.swift              # Transport-strip indicator
```

## Implementation plan

### AirPlay

1. **AirPlay 2 on macOS** is surfaced by the system; apps generally don't route audio explicitly — it follows the system output device. `AVRoutePickerView` (AppKit wrapper) gives a button that opens the system picker.

2. **`AirPlayButton`** — `NSViewRepresentable` around `AVRoutePickerView`. Styled to match the app. Clicking opens the popover with AirPlay devices and system output devices.

3. **Route change observation** — observe `AVAudioEngineConfigurationChange` and audio device changes via `CoreAudio` HAL property listeners. On change:
   - Re-acquire the canonical format.
   - Phase 1's `EngineGraph` already handles reconfiguration; ensure this path is solid.
   - Update UI indicator ("Playing on Living Room").

4. **Gapless on AirPlay**: AirPlay 2 supports gapless in theory but implementations vary. Treat it as best-effort; keep the `GaplessScheduler` unchanged; document that gapless on AirPlay depends on the receiver.

### Google Cast

5. **SDK**: `google-cast-sdk` via SPM (official). Initialise `GCKCastContext` with the Bòcan receiver app ID (use the default media receiver `CC1AD845` if no custom receiver is registered — it supports audio).

6. **Discovery** — `GCKDiscoveryManager` runs in the background; populates a `@Published` list of discovered devices.

7. **Session management** — `GCKSessionManager` events map to a `CastSessionState` enum (`idle | connecting | connected(GCKCastSession) | disconnecting | error(Error)`).

8. **Media serving**:
   - Cast devices can't read sandboxed local files. Start a local HTTP server bound to `127.0.0.1` on an ephemeral port **only when casting** — Google Cast devices on the LAN reach it via the Mac's LAN IP.
   - Use `Network.framework` (`NWListener`) for the server; implement minimal HTTP range support (`Range: bytes=…`).
   - Serve decoded PCM? No — serve the original container when Cast supports it, transcode on-the-fly via the FFmpeg bridge otherwise.
   - Supported containers on default receiver: MP3, AAC (M4A), WebM, Vorbis (OGG), FLAC (limited), WAV.
   - Unsupported (DSD, APE, WMA, etc.): transcode to FLAC on-the-fly, serve as `audio/flac`.

9. **`CastMediaItemBuilder`**:
   - URL: `http://<lan-ip>:<port>/tracks/<token>` — token is short-lived and rate-limited.
   - `GCKMediaInformation` with content type, metadata (`GCKMediaMetadata(metadataType: .musicTrack)`), images (cover art URL served from the same server).
   - Preload the next item via `GCKRemoteMediaClient.queueInsertItems` for gapless-on-receiver behaviour (the default receiver supports a queue).

10. **Local engine while casting**:
    - **Mute** local output but keep the engine running (so UI sees timecode), OR
    - **Pause** the local engine and drive UI from `GCKRemoteMediaClient.mediaStatus` updates (better — no wasted decoding on the Mac).
    - Choose the second: when a cast session is active, the local engine is stopped; the `QueuePlayer` is still the logical owner of state but its `Transport` calls delegate to the cast route.

11. **Volume sync**:
    - Local volume = app's output gain.
    - Cast volume = `GCKCastSession.currentDeviceVolume`.
    - A slider in the transport strip binds to the active route's volume. Observe remote changes and update the slider without bouncing.
    - **Never** change the system volume or the output device volume — too invasive.

12. **Transport commands** — Play/Pause/Next/Prev/Seek all flow through the active route. `QueuePlayer.Transport` gains a route-aware adapter.

13. **Fallback and failure**:
    - Remote session drops unexpectedly → announce via toast, wait 5s for re-connect, then fall back to local and resume at last known position.
    - If a track can't play on the receiver (codec refused), log, skip to next, toast the user.

14. **`RoutePicker` UI**:
    - Single button in the toolbar; popover shows:
      - Top section: System Output (follows OS), AirPlay devices (via `AVRoutePickerView` embedded).
      - Bottom section: Google Cast devices (from discovery).
    - Active device checkmarked; tap to switch.
    - Refresh button for Cast (triggers re-scan).

15. **Privacy & entitlements**:
    - `NSLocalNetworkUsageDescription` — required for mDNS / LAN traffic on macOS 14+. Provide a clear reason ("Bòcan uses your local network to discover and stream to cast-enabled speakers.").
    - `NSBonjourServices` with `_googlecast._tcp` and any AirPlay bonjour types needed.
    - Entitlement `com.apple.security.network.server` for the embedded HTTP server, `network.client` for Cast discovery.

## Definitions & contracts

### `Route`

```swift
public enum Route: Sendable, Hashable, Identifiable {
    case local
    case airPlay(id: String, name: String)
    case cast(id: String, name: String)

    public var id: String { /* derive */ }
}
```

### `RouteManager`

```swift
public actor RouteManager {
    public var current: Route { get }
    public var devices: AsyncStream<[Route]> { get }
    public func activate(_ route: Route) async throws
    public func deactivateToLocal() async
}
```

### `Transport` adapter

```swift
struct RouteAwareTransport: Transport {
    let local: QueuePlayer
    let cast: CastTransport?
    // All methods dispatch to local or cast based on RouteManager.current
}
```

## Context7 lookups

- `use context7 AVRoutePickerView macOS NSViewRepresentable`
- `use context7 CoreAudio HAL property listener output device change Swift`
- `use context7 Google Cast iOS SDK Swift SessionManager queue`
- `use context7 Google Cast MediaInformation GCKRemoteMediaClient load`
- `use context7 Network.framework NWListener HTTP range server Swift`
- `use context7 macOS sandbox local network NSLocalNetworkUsageDescription`

## Dependencies

- Google Cast SDK — `https://github.com/google/cast-ios-sdk` (has macOS support via Catalyst; if that's a problem, consider the `google-cast-mac-sdk` binary framework — verify licensing and SPM packaging).
  - Pin exact version.
  - Document LGPL/BSD terms. (Google Cast SDK is proprietary but free-to-use under Google's terms.)

## Test plan

Integration tests require real devices; most can't be automated. Do:

### Unit

- `RouteManager` state machine transitions correctly: activate, fail, fall-back.
- `CastMediaServer` serves a byte range correctly; handles `HEAD` + `GET`; closes idle connections.
- `CastMediaItemBuilder` produces valid `GCKMediaInformation` for MP3, FLAC, and DSD-needing-transcode inputs.
- Volume binding updates without feedback loops given observed remote changes (mock session).

### Manual / integration

- AirPlay: pick an AirPlay 2 speaker → audio moves there without gap; pause/play/next work.
- Cast: pick a Google speaker → same expectations; gapless via `queueInsertItems`; dropping Wi-Fi → auto-fall-back to local.
- Two sessions in succession: AirPlay, then Cast, then back to local; no resource leaks (verify local HTTP server torn down).

### Security

- Local HTTP server binds only to `127.0.0.1` and the LAN interface; not the internet. Verify via netstat.
- Tokens in URLs are random, per-session, and expire when the session ends.
- Reject requests without the session token.

## Acceptance criteria

- [ ] AirPlay picker works; transport commands control playback.
- [ ] Google Cast picker discovers devices on the LAN; casting plays audio on them.
- [ ] Volume sync bidirectional.
- [ ] Route fall-back on failure is automatic and explained.
- [ ] No persistent HTTP server or discovery traffic when no cast is active.
- [ ] Sandbox + entitlements correct.
- [ ] 80%+ coverage on the non-SDK code.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **Sandbox + LAN**: macOS requires `NSLocalNetworkUsageDescription` and the `NSBonjourServices` list, otherwise discovery silently fails. The prompt appears on first discovery; handle rejection by disabling Cast UI.
- **Cast SDK and macOS sandbox**: historically the SDK shipped iOS-only; verify SPM build for macOS target (may need Catalyst). If Catalyst, UI integration has quirks with AppKit — plan.
- **Local HTTP server** in a sandboxed app needs `network.server` entitlement. Bind explicitly to `0.0.0.0` (so LAN clients reach) but firewall: use session tokens in the URL to avoid exposing content to other LAN hosts.
- **Transcoding on-the-fly**: start the FFmpeg pipeline and feed its output as the HTTP response body (streaming). Don't buffer to disk unless the receiver requires `Content-Length`. Many receivers require Content-Length; if so, transcode into a bounded in-memory ring or temp file and send chunked only when supported.
- **Gapless on Cast**: the default receiver honours `preloadTime` on queue items but real-world behaviour varies. Set a 10s preload; accept small gaps on some devices.
- **Volume feedback loops**: watch for the observed remote volume triggering a `setVolume` back to the remote; debounce by 150ms and ignore changes whose source is the same cycle.
- **AirPlay selection**: on macOS, AirPlay is actually picked at the system level for most apps; ensure our engine follows system routing (standard AVAudioEngine behaviour). Document.
- **Network privacy prompt**: surface a clear banner explaining why the prompt appears when the user first opens the picker, or the prompt seems random.
- **Discovery lifetime**: run discovery only when picker open or cast is active. Background discovery drains battery and triggers repeated log spam.
- **Firewalled users**: some users block LAN; if discovery returns empty within 3s, show a helpful "Check that local network access is allowed for Bòcan" hint.
- **HTTP range requests**: receivers often seek by range. Implement `Range: bytes=N-M` correctly; partial responses are 206, with `Content-Range`.
- **Track ordering during cast**: `GCKRemoteMediaClient.queueJumpToItem` may not reliably work mid-track; pause, jump, play — state machine handles it explicitly.
- **Cast SDK updates**: pin the version and review new versions for proprietary telemetry before bumping.

## Handoff

Phase 16 (Distribution) expects:

- All entitlements required by this phase (`network.server`, `network.client`, `NSLocalNetworkUsageDescription`, `NSBonjourServices`) are captured in the entitlements file and the `Info.plist` and will be included in the notarised build.
