# Phase 5 — Playback Queue & Gapless Playback

> Prerequisites: Phases 0–4 complete. UI can trigger single-file playback.
>
> Read `phases/_standards.md` first.

## Goal

Turn the single-file player into a real music player: a queue you can manipulate, next/previous, repeat, shuffle (with exclusions and personality), **gapless transitions**, and system-level Now-Playing integration (media keys, Control Centre, AirPods).

## Non-goals

- Playlists as persistent entities — Phase 6.
- Smart playlists — Phase 7.
- EQ / ReplayGain on output — Phase 9 (but the engine must already have the insertion point from Phase 1).
- Crossfade between tracks — Phase 9.

## Outcome shape

```
Modules/Playback/
├── Package.swift
├── Sources/Playback/
│   ├── PlaybackQueue.swift            # actor, the model
│   ├── QueueItem.swift                # Wraps a Track.ID + resolved bookmark URL
│   ├── QueuePlayer.swift              # Transport conformer; orchestrates engine + queue
│   ├── Shuffle/
│   │   ├── ShuffleStrategy.swift      # protocol
│   │   ├── FisherYatesShuffle.swift   # deterministic with seed
│   │   └── SmartShuffle.swift         # weighted
│   ├── Gapless/
│   │   ├── GaplessScheduler.swift     # pre-decode + sample-accurate handoff
│   │   └── FormatBridge.swift         # converter node when formats differ
│   ├── NowPlaying/
│   │   ├── NowPlayingCentre.swift     # MPNowPlayingInfoCenter wrapper
│   │   └── RemoteCommands.swift       # MPRemoteCommandCenter bindings
│   ├── History/
│   │   └── PlayHistoryRecorder.swift  # writes to play_history on rules
│   ├── Persistence/
│   │   └── QueuePersistence.swift     # save/restore queue across launches
│   └── Errors.swift
└── Tests/PlaybackTests/
    ├── PlaybackQueueTests.swift
    ├── QueuePlayerTests.swift
    ├── ShuffleTests.swift
    ├── GaplessTests.swift
    ├── RepeatModeTests.swift
    ├── HistoryRecorderTests.swift
    ├── NowPlayingTests.swift
    └── Fixtures/
        ├── gapless-a.flac              # First half of a continuous sine sweep
        ├── gapless-b.flac              # Second half, boundaries aligned
        └── mixed-format-album/...
```

Wire into `UI/ContextMenus.swift`: Play Now, Play Next, Add to Queue, Play Album, Shuffle Album, Play Artist.

Add a new sidebar item "Up Next" showing the current queue, with drag-reorder and per-row remove.

## Implementation plan

1. **`Modules/Playback` Swift Package**, depends on `AudioEngine`, `Persistence`, `Observability`.

2. **`QueueItem`**:
   ```swift
   public struct QueueItem: Sendable, Identifiable, Hashable {
       public let id: UUID                 // queue-local; different from Track.ID
       public let trackID: Int64
       public let bookmark: BookmarkBlob
       public let duration: TimeInterval
       public let sourceFormat: AudioSourceFormat  // used for gapless compatibility check
   }
   ```

3. **`PlaybackQueue`** (actor) — owns:
   - `items: [QueueItem]` — the main queue (what plays after the current).
   - `history: [QueueItem]` — bounded (e.g. 256) for back-navigation.
   - `currentIndex: Int?`
   - `repeatMode: RepeatMode` (off / all / one)
   - `shuffle: ShuffleState` (off / on(seed))
   - Public ops: `append(_:)`, `appendNext(_:)`, `insert(_:at:)`, `remove(ids:)`, `move(from:to:)`, `clear()`, `replace(with: [QueueItem], startAt:)`, `advance() -> QueueItem?`, `retreat() -> QueueItem?`, `peekNext() -> QueueItem?`.
   - Emits `AsyncStream<QueueChange>` for the UI.
   - Every mutation is O(n) or better; big-bulk ops (append 5k tracks) must complete in < 50ms.

4. **`ShuffleStrategy`** protocol:
   ```swift
   public protocol ShuffleStrategy: Sendable {
       func shuffled(_ items: [QueueItem], seed: UInt64) -> [QueueItem]
   }
   ```
   - `FisherYatesShuffle` — deterministic Fisher–Yates with a seeded RNG (`SystemRandomNumberGenerator` replaced with `Xoshiro256StarStar` seeded from the seed).
   - `SmartShuffle` — weights each item by:
     - `+2` per star of `rating` (0 if unrated)
     - `+1` if `loved`
     - `+0.5 * log(play_count + 1)`
     - `-3` if `excluded_from_shuffle`
     - `-2` if played in the last 24h
     - Tracks from the same album/artist are spaced out (bubble apart: after shuffle, scan and swap adjacent same-album pairs up to N hops).
     - Excluded tracks (`excluded_from_shuffle = 1`) are filtered out entirely, not merely down-weighted.

5. **`QueuePlayer`** — conforms to `Transport` from Phase 1 so the UI can replace the engine. Responsibilities:
   - Given `PlaybackQueue` + `AudioEngine`, when `advance()` produces an item, call `engine.load(_:)` then `engine.play()`.
   - Listen to `engine.state`: when `.ended` arrives for the current item, act on `repeatMode`:
     - `.one` → `seek(0)` + `play`.
     - `.all` / `.off` → advance; if `advance()` returns nil, stop.
   - `next()` / `previous()` user commands call into `PlaybackQueue.advance/retreat`.
   - Exposes:
     ```swift
     public func play(item: QueueItem) async throws
     public func play(track: Track.ID) async throws
     public func enqueueNext(_ items: [QueueItem]) async
     public func enqueueLast(_ items: [QueueItem]) async
     public func playAlbum(_ albumID: Int64, shuffle: Bool) async throws
     public func playArtist(_ artistID: Int64, shuffle: Bool) async throws
     public func next() async throws
     public func previous() async throws
     public func setRepeat(_ mode: RepeatMode) async
     public func setShuffle(_ on: Bool) async
     public func setStopAfterCurrent(_ enabled: Bool) async
     ```

6. **`GaplessScheduler`** — the heart of the phase.
   - When `engine.currentTime` crosses `duration - preroll` (configurable, default 5.0s), construct the next `Decoder` for the peek-next item and begin pre-decoding into an in-memory buffer queue (~200ms worth of buffers).
   - At handoff time:
     - If the peek-next format is **compatible** with the current player node's format (same sample rate, channel count, bit depth, interleaving), schedule the next item's first buffer at `AVAudioTime` equal to the exact end sample of the current item. Use the same player node (or a second one fed into the same mixer) and let `AVAudioPlayerNode` stitch it with zero gap.
     - If formats **differ**, route the new decoder through a `FormatBridge` (`AVAudioConverter` + `AVAudioMixerNode`) and use a second player node so you can cross-fade for 5–20ms to mask the converter startup click, OR pause briefly at a zero-crossing. Prefer the former; document the trade-off.
   - On successful handoff, promote the second node to primary and tear down the old one.
   - `GaplessScheduler` lives inside `QueuePlayer` and uses an insertion point on `AudioEngine` exposed in Phase 1 (`AudioGraphInsertionPoint`).

7. **`NowPlayingCentre`**:
   - On track change, populate `MPNowPlayingInfoCenter.default().nowPlayingInfo` with: title, artist, album, duration, elapsed time, playback rate, artwork (`MPMediaItemArtwork` from the cover-art cache).
   - Update elapsed time every 1s while playing (don't spam; 1 Hz is enough — Control Centre interpolates).
   - Set `MPNowPlayingInfoCenter.default().playbackState`.

8. **`RemoteCommands`**:
   - Bind `play`, `pause`, `togglePlayPause`, `nextTrack`, `previousTrack`, `changePlaybackPosition`.
   - Disable `skipForward`/`skipBackward` unless there's a future podcast use case (we're a music player; skipping 15s is odd here).
   - Forward every command to `QueuePlayer`.

9. **`PlayHistoryRecorder`** — subscribes to `QueuePlayer` state:
   - When a track has been played for ≥ 50% of its duration OR ≥ 4 minutes (whichever first), insert into `play_history` and increment `tracks.play_count`, set `last_played_at`.
   - Skips (user hit next before threshold) increment `tracks.skip_count` and record `skip_after_seconds`.
   - Pause/resume doesn't double-count.
   - Runs as an async consumer of `engine.state` plus `queue` changes.

10. **`QueuePersistence`** — serialises the queue + history + currentIndex + shuffle + repeat into the `settings` table as `playback.queue.v1` JSON. Restored on app launch (UI binds the restored queue and waits for the user to press play).

11. **UI wiring** (in `Modules/UI`):
    - Enable the stubbed context menu items.
    - Add **Up Next** sidebar row that opens a `QueueView` with drag-reorder and remove.
    - Transport strip: hook prev/next buttons, show "Shuffle", "Repeat", and "Stop After Current" toggles. Stop After Current is a one-shot flag: when enabled and the current track ends, playback stops and the flag resets.
    - Double-clicking a track in a list now: **play that track, enqueue the rest of the current view after it** (iTunes/Music behaviour). Option-double-click → play just this one.
    - Drag a track onto the Up Next sidebar row to enqueue.

12. **Cross-cutting**: `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` require `AVFAudio` and work on macOS without `AVAudioSession`. Verify on macOS 14+.

## Definitions & contracts

### `RepeatMode`, `ShuffleState`

```swift
public enum RepeatMode: String, Sendable, Codable { case off, all, one }

public enum ShuffleState: Sendable, Codable, Equatable {
    case off
    case on(seed: UInt64)
}
```

### `QueueChange`

```swift
public enum QueueChange: Sendable {
    case reset(items: [QueueItem], currentIndex: Int?)
    case appended(items: [QueueItem])
    case insertedNext(items: [QueueItem])
    case removed(ids: [QueueItem.ID])
    case moved(fromIndex: Int, toIndex: Int)
    case cleared
    case currentChanged(newIndex: Int?, previousIndex: Int?)
    case repeatChanged(RepeatMode)
    case shuffleChanged(ShuffleState)
    case stopAfterCurrentChanged(Bool)
}
```

### `AudioSourceFormat`

```swift
public struct AudioSourceFormat: Sendable, Hashable {
    public let sampleRate: Double
    public let bitDepth: Int
    public let channelCount: Int
    public let isInterleaved: Bool
    public let codec: String           // "flac", "mp3", etc
    public var isGaplessCompatible: Bool  // true when safe to stitch without converter
}
```

## Context7 lookups

- `use context7 AVAudioPlayerNode scheduleBuffer at AVAudioTime sample accurate`
- `use context7 AVAudioTime hostTime sample time conversion`
- `use context7 AVAudioEngine connect format mixer`
- `use context7 AVAudioConverter real time`
- `use context7 MPNowPlayingInfoCenter macOS artwork`
- `use context7 MPRemoteCommandCenter macOS handlers`
- `use context7 Swift 6 actor AsyncStream multiple consumers`

## Dependencies

None new. (MediaPlayer is a system framework.)

## Test plan

### Queue algebra (property-based)

- Arbitrary sequences of append/insertNext/remove/move/clear — invariants hold:
  - `currentIndex` is always `nil` or in `0..<items.count`.
  - `items.count` equals expected after each op.
  - `advance()` and `retreat()` are inverses inside the bounds.
- Removing the currently-playing item advances to the next one (or stops if none).

### Shuffle

- Seeded FY is deterministic: same seed → same order.
- Excluded tracks never appear in shuffled output.
- Smart shuffle: statistical test — over 1000 shuffles, high-rated tracks average earlier positions than low-rated; tracks from same album are not adjacent in ≥ 90% of runs.

### Repeat modes

- `.off` at end → stops; `.all` → wraps; `.one` → replays indefinitely.
- Changing `repeatMode` mid-playback takes effect at the next boundary without restarting the current track.

### Gapless

- Commit two 1-second sine fixtures cut from a continuous sweep. Play them back-to-back with gapless on. Record output via `AVAudioEngine.installTap(onBus:)`. Concatenate the captured buffers and run an FFT/zero-crossing analysis — no gap, no phase discontinuity > 1 sample.
- Mixed format: a 44.1/16 FLAC followed by a 48/24 WAV — the bridge engages, output is continuous within a < 5ms crossfade tolerance (document that truly sample-accurate gapless across format changes isn't always possible).
- Pre-decode timing: if the current item has < `preroll` seconds remaining, the next decoder is constructed and at least one buffer pre-decoded (verify with an injected clock).
- Next-track format compatibility check is symmetric and transitive on identical-format triples.

### Remote commands & Now Playing

- Invoking `MPRemoteCommandCenter.togglePlayPauseCommand` via test harness toggles state.
- `nowPlayingInfo` carries `MPMediaItemPropertyTitle` etc. after each track change.
- Artwork populated from the cover-art cache.

### History

- Playing a 3-minute track to its end increments `play_count` by 1 and inserts one `play_history` row.
- Seeking to 1:50 then ending counts as a play (≥ 50% elapsed).
- Pausing at 0:30 for 10 minutes then resuming and playing to the end still counts as one play, not two.
- Hitting next at 0:10 increments `skip_count`, not `play_count`.

### Persistence

- Save a 100-item queue with index 42, shuffle on with seed 0x1234, repeat `.all`. Kill the app (simulated). Restart. Queue restored identically.
- Tracks whose files have disappeared on restart surface as disabled items in the restored queue (visible but unplayable).

### UI smoke

- Select 20 tracks → "Play" → queue is those 20, playback starts on the first.
- Option-double-click plays a single track without enqueuing siblings.
- Drag a track onto Up Next, see it appear there.

## Acceptance criteria

- [ ] Queue a whole album, playback runs end-to-end with no audible gaps on a known gapless test album (e.g. _Dark Side of the Moon_).
- [ ] Mixed-format queue still plays continuously (within the documented tolerance).
- [ ] Media keys / AirPods / Control Centre all drive transport and next/previous.
- [ ] Shuffle respects exclusion; smart shuffle feels "musical" (subjective but not obviously broken).
- [ ] Repeat modes behave correctly.
- [ ] "Stop after current" halts playback at the end of the current track; the flag auto-resets and the queue position is preserved.
- [ ] Queue persists across launches.
- [ ] Play counts and history roll up correctly.
- [ ] 80%+ coverage on `Modules/Playback`.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **Sample-accurate time**: `AVAudioTime(sampleTime:atRate:)` must use the **same rate** as the player node's output format. Mix those up and gapless falls apart by exactly one sample rate's ratio.
- **`AVAudioPlayerNode` completion callbacks** fire on a background thread. Hop to the `QueuePlayer` actor before mutating state.
- **Two player nodes for gapless**: don't start the second one via `play()` — it starts implicitly when its first buffer's `AVAudioTime` arrives. Starting it manually creates a race.
- **`preroll` too small**: on very slow disks or big FLACs, 5s may not be enough to fully pre-decode. Start with 5s but make it configurable.
- **Cover art in `MPMediaItemArtwork`**: must be an `NSImage`; supply a bounds-handler that returns an image at requested size. Don't ship a 4k image to the Dynamic Island.
- **MPRemoteCommandCenter** handlers return `MPRemoteCommandHandlerStatus`. Always return a value; returning success when the op failed confuses Control Centre.
- **Mixed gapless**: honest truth — if the formats differ you cannot be perfectly sample-accurate without a pre-rendered crossfade. Accept a tiny crossfade; put it behind a setting if audiophiles grumble.
- **Stop-after-current + repeat-one**: if both are enabled simultaneously, stop-after-current wins — the track plays once then stops and the flag resets.
- **Shuffle + replay**: if the user disables shuffle mid-playback, the remaining queue should become the un-shuffled rest of the album/source — not just "the same random order with shuffle label off". Store the original source order so you can reconstruct.
- **History double-writes**: if the app crashes after the half-way mark but before the `.ended` event, you'll lose the play. A heuristic is to write the row immediately when the rule becomes true (≥ 50% OR ≥ 4 min), then mark "ended cleanly" only on the true end. Tune to avoid duplicates on seek-backs.
- **`excluded_from_shuffle`** only applies to random/shuffle selection. Manually adding such a track to the queue still plays it — don't filter in the queue itself.
- **Media key capture on macOS 14+**: works via `MPRemoteCommandCenter` without special entitlements, but only if the app is in foreground OR has played audio recently (Now Playing badge). Document this reality.
- **Watcher thread safety**: `MPNowPlayingInfoCenter.nowPlayingInfo` is not thread-safe. Always update from `@MainActor`.

## Handoff

Phase 6 (Manual Playlists) expects:

- `QueuePlayer.playAlbum` / `playArtist` are implemented generically in terms of "play a sequence of Track.IDs in this order"; Phase 6 will call the same entry point with a playlist's track IDs.
- Context menus have "Add to Playlist ▸" as a stub that Phase 6 populates.
- `QueueView` understands the `QueueItem` model cleanly; Phase 6 will reuse row rendering in the playlist view.
