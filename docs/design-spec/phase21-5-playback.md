# Phase 21-5: Podcasts - Playback integration (PlayableSource.podcast, resume, position write-back)

> Depends on: `phase21-0-overview.md`, `phase21-1-persistence.md`,
> `phase21-4-subscriptions.md` (the `PodcastService` state bridge). Touches
> **Playback** (the `PlayableSource` enum, `QueuePlayer`, queue persistence) and
> **App** (wiring the resolver). Does **not** import `Podcasts` from `Playback`.
>
> Provides: a playable `.podcast` source, per-episode resume on load, position
> write-back on a timer + pause/stop/quit, mark-played on completion, scrobble
> skip, and podcast Now-Playing media type. This is the slice that delivers the
> user's non-negotiable resume-position requirement at the engine level.

## Goal

Make a podcast episode a first-class queue item that plays through the existing
`QueuePlayer` / `AudioEngine` pipeline, resumes from its saved position, writes
that position back continuously, and marks itself played when finished, all
without `Playback` knowing anything about feeds or the `Podcasts` module. The
bridge is a protocol (`PodcastEpisodeResolving`) injected by `App`, exactly like
`SubsonicStreamResolving`.

## Non-goals

- No UI play buttons / episode rows (phase 21-9 builds the episode list and calls
  into the player). This slice makes the player able to play a podcast item.
- No downloads (phase 21-6); the resolver returns the enclosure URL for now.
- No speed/skip transport controls (phase 21-10); those are UI over existing
  `setRate` / `seek`.

## The PlayableSource change (exact edits)

`Modules/Playback/Sources/Playback/PlayableSource.swift` currently has three
cases. Add a fourth. The edits below are exhaustive; the file's existing shape is
known.

### Add the case

```swift
    /// A podcast episode from the local Podcasts library. Identified by its
    /// canonical feed URL and the episode's feed `guid`. The audio (a remote
    /// enclosure, or a local file once downloaded), the resume position, and the
    /// position write-back are all resolved through an App-injected
    /// `PodcastEpisodeResolving`; Playback never imports the Podcasts module.
    case podcast(feedURL: URL, episodeGUID: String)
```

### `isRemote`

```swift
    public var isRemote: Bool {
        switch self {
        case .localBookmark: false
        case .subsonic, .internetRadio, .podcast: true
        }
    }
```

### `isLiveStream`

Podcasts are finite and seekable, so they are **not** live streams:

```swift
    public var isLiveStream: Bool {
        switch self {
        case .localBookmark, .subsonic, .podcast: false
        case .internetRadio: true
        }
    }
```

### Accessor

```swift
    /// The (feedURL, guid) pair when the source is `.podcast`. `nil` otherwise.
    public var podcastEpisode: (feedURL: URL, guid: String)? {
        if case let .podcast(feedURL, guid) = self { return (feedURL, guid) }
        return nil
    }
```

### Codable

Add to `Kind`:

```swift
    private enum Kind: String, Codable {
        case localBookmark
        case subsonic
        case internetRadio
        case podcast
    }
```

Add coding keys (the existing `CodingKeys` has `kind, bookmark, serverID, songID,
streamURL`):

```swift
        case feedURL
        case episodeGUID
```

Decode arm (in `init(from:)`):

```swift
        case .podcast:
            let feedURL = try container.decode(URL.self, forKey: .feedURL)
            let guid = try container.decode(String.self, forKey: .episodeGUID)
            self = .podcast(feedURL: feedURL, episodeGUID: guid)
```

Encode arm (in `encode(to:)`):

```swift
        case let .podcast(feedURL, guid):
            try container.encode(Kind.podcast, forKey: .kind)
            try container.encode(feedURL, forKey: .feedURL)
            try container.encode(guid, forKey: .episodeGUID)
```

> The discriminated encoding is forward-compatible: no queue-schema version bump
> is needed. Existing v2 blobs decode unchanged; new podcast items persist with
> `"kind": "podcast"`. Update the `PlayableSource` Codable round-trip tests to
> include the new case (the `Playback` module CLAUDE.md calls this out).

## The resolver seam

Add `Modules/Playback/Sources/Playback/PodcastEpisodeResolving.swift` with the
protocol from `phase21-0-overview.md`. It mirrors `SubsonicStreamResolving.swift`
exactly in spirit: a `Sendable` protocol the App implements.

```swift
public protocol PodcastEpisodeResolving: Sendable {
    func audioURL(feedURL: URL, episodeGUID: String) async throws -> URL
    func resumePosition(feedURL: URL, episodeGUID: String) async -> TimeInterval
    func persistPosition(feedURL: URL, episodeGUID: String, position: TimeInterval, duration: TimeInterval) async
    func markPlayed(feedURL: URL, episodeGUID: String) async
}
```

Inject it into `QueuePlayer` the same way `subsonicResolver` is injected (a new
init parameter `podcastResolver: (any PodcastEpisodeResolving)?`, stored
property). It is optional so existing tests that do not exercise podcasts can pass
`nil`.

## QueuePlayer changes

All of these mirror existing `.subsonic` / `.internetRadio` handling; find each
site by searching for the existing `case .subsonic` / `case .internetRadio`
matches (the Playback exploration enumerated them).

1. **URL resolution** (where the item's `playableSource` is turned into a URL for
   `engine.load`): add an arm

   ```swift
   else if case let .podcast(feedURL, guid) = item.playableSource {
       guard let resolver = self.podcastResolver else {
           throw PlaybackError.incompatibleFormat(reason: "No podcast resolver configured")
       }
       url = try await resolver.audioURL(feedURL: feedURL, episodeGUID: guid)
   }
   ```

   The returned URL is either a remote `https://…` enclosure (the engine's
   `DecoderFactory` routes HTTP/HTTPS to `FFmpegDecoder` automatically, which is
   correct for a streamed podcast) or a local `file://…` download (sniffed and
   decoded like any local file). No `DecoderFactory` / engine change is required.

2. **Resume on load**: after the current item is loaded but before/at the start of
   playback, if it is a podcast item, consult the resolver and seek:

   ```swift
   if case let .podcast(feedURL, guid) = item.playableSource {
       let resume = await resolver.resumePosition(feedURL: feedURL, episodeGUID: guid)
       if resume > 1 { try? await self.engine.seek(to: resume) }
   }
   ```

   This is **per-episode** resume and is independent of the existing global
   `UserDefaults["playback.resumePosition"]` mechanism (which restores the single
   last position of the restored queue). For a podcast item, the per-episode
   position is authoritative; do not also apply the global resume to a podcast
   item (guard the global-resume path to skip when the current item is `.podcast`,
   so the two do not fight).

3. **Position write-back on a timer**: the player already runs a periodic update
   loop while playing (the scrobble/history update, ~5 s cadence). In that same
   tick, if the current item is `.podcast`, call:

   ```swift
   await resolver.persistPosition(feedURL: feedURL, episodeGUID: guid,
                                  position: currentTime, duration: duration)
   ```

   Reuse the existing loop; do not add a second timer.

4. **Write-back on pause / stop**: in `pause()` and `stop()`, if the (about to be
   suspended) current item is a podcast, persist the current position once before
   tearing down. This guarantees a position even between the 5 s ticks.

5. **Write-back on app quit**: the existing `savePositionForSuspend()` (called
   from the `willTerminate` observer) must, when the current item is a podcast,
   also call `persistPosition` through the resolver, not only write the global
   `UserDefaults` key. Add that branch.

6. **Mark played on completion**: in `handleTrackEnded` (natural end) and the
   gapless-transition handler, if the finishing item was a podcast, call
   `await resolver.markPlayed(feedURL:episodeGUID:)`. (The resolver / service also
   auto-marks when a position write lands within the completion tail, per 21-4;
   both paths are idempotent.)

7. **Scrobble skip**: in the scrobble dispatch switch (where `.internetRadio`
   already early-returns because there is no local track row), add the podcast
   early return so episodes never scrobble to Last.fm / ListenBrainz:

   ```swift
   if case .podcast = item.playableSource { return }
   ```

8. **MPNowPlaying media type**: when the current item is a podcast, set
   `MPNowPlayingInfoPropertyMediaType = .podcast` (in `NowPlayingCentre`) and map
   the metadata: `MPMediaItemPropertyTitle` = episode title (the QueueItem's
   `title`), `MPMediaItemPropertyArtist` / `MPMediaItemPropertyPodcastTitle` =
   show name (the QueueItem's `artistName`). The lock-screen / Control Center
   then shows podcast-appropriate transport.

## Building a podcast QueueItem

The UI (phase 21-9) constructs the `QueueItem`. Define the construction contract
here so the UI and player agree. A podcast `QueueItem`:

- `playableSource = .podcast(feedURL: canonicalFeedURL, episodeGUID: guid)`.
- `title` = episode title; `artistName` = show title (so Now Playing's
  artist-slot shows the show, per the brief); `genre` = nil.
- `duration` = the episode's feed duration (or 0 when unknown; the engine fills in
  the real decoded duration once loaded).
- `albumID` / `artistID` = nil (no local catalogue rows).
- `trackID` = the **same sentinel convention** that `.subsonic` and
  `.internetRadio` items already use for non-local items (they do not point at a
  real `tracks` row). Mirror whatever `QueueItem` construction those cases use; do
  not invent a new scheme, and ensure any code that does `TrackRepository.fetch(id:
  trackID)` already skips non-local items (it must already, for Subsonic/radio).

Provide a small helper so the UI does not duplicate this. It can live in the UI
layer (it needs episode + podcast data which UI has), but the **field contract
above is binding**: if Now Playing is to show the show name in the artist slot
with zero new plumbing, `artistName` must carry the show title.

## Decoder / seek notes

- A streamed enclosure is a finite static file with `Content-Length` and HTTP
  range support, so `FFmpegDecoder` over HTTP **can seek**, which is what makes
  resume-on-load work for streamed episodes. Verify this end-to-end on a real
  feed; if a particular host does not honour range requests, seeking that
  episode will be best-effort. This is the strongest argument for phase 21-6
  (download then play a local file = rock-solid seek). Note it; do not block MVP
  on it.
- Do **not** route podcasts through `AVAudioFile` / the Subsonic
  full-download-before-ready cache; that path exists because `AVAudioFile`
  snapshots length at open. `FFmpegDecoder` is the right decoder for a streamed
  enclosure and is selected automatically by `DecoderFactory` for http(s) URLs.

## App-layer wiring

In `App/BocanApp.swift` (or wherever the object graph is built, alongside the
`SubsonicStreamResolver` wiring):

```swift
struct AppPodcastResolver: PodcastEpisodeResolving {
    let service: PodcastService
    func audioURL(feedURL: URL, episodeGUID: String) async throws -> URL {
        try await service.audioURL(feedURL: feedURL, episodeGUID: episodeGUID)
    }
    func resumePosition(feedURL: URL, episodeGUID: String) async -> TimeInterval {
        await service.resumePosition(feedURL: feedURL, episodeGUID: episodeGUID)
    }
    func persistPosition(feedURL: URL, episodeGUID: String, position: TimeInterval, duration: TimeInterval) async {
        await service.saveProgress(feedURL: feedURL, episodeGUID: episodeGUID, position: position, duration: duration)
    }
    func markPlayed(feedURL: URL, episodeGUID: String) async {
        await service.markPlayed(feedURL: feedURL, episodeGUID: episodeGUID)
    }
}
```

Pass an instance as `podcastResolver:` when constructing `QueuePlayer`.

## Context7 lookups

- Apple `MediaPlayer`: `MPNowPlayingInfoPropertyMediaType` / `.podcast`,
  `MPMediaItemPropertyPodcastTitle`, and which remote commands suit podcasts
  (skip-forward / skip-backward intervals) for the lock screen.
- FFmpeg `http` protocol seekability / range requests (confirm seek works on a
  finite remote enclosure) - reference only; no code change.

## Dependencies

None new. `MediaPlayer` is already linked by `Playback`.

## Test plan

`Modules/Playback/Tests/PlaybackTests/` (Swift Testing), with a stub
`PodcastEpisodeResolving` (records calls; returns a canned `file://` fixture URL
and a canned resume position):

- **PlayableSource Codable**: `.podcast` round-trips; an old v2 blob without the
  new keys still decodes; a v2 blob containing a `.podcast` item decodes; the
  existing v1->v2 migration test still passes.
- **Resume on load**: loading a podcast item whose resolver returns position N
  seeks the engine to N (assert via a fake engine / Transport). A resume of 0 or
  <=1 does not seek.
- **Position write-back**: the periodic tick calls `persistPosition` with the
  current time while a podcast plays; pause and stop each trigger one final
  `persistPosition`; a non-podcast item triggers none.
- **Mark played**: a podcast item reaching `.ended` calls `markPlayed` exactly
  once.
- **Scrobble skip**: a completed podcast item does not enqueue a scrobble (assert
  the history recorder / scrobble path was not invoked).
- **No resolver**: a `.podcast` item with `podcastResolver == nil` fails the load
  cleanly with `PlaybackError`, not a crash.
- Run `make test-playback` (the module's full suite is the final gate per its
  CLAUDE.md).

## Acceptance criteria

- [ ] `PlayableSource.podcast` exists with correct `isRemote` (true),
      `isLiveStream` (false), accessor, and Codable arms; round-trip tests pass.
- [ ] `PodcastEpisodeResolving` is declared in `Playback`; `QueuePlayer` takes an
      optional `podcastResolver` and never imports `Podcasts`.
- [ ] Playing a podcast item resolves its URL, seeks to the saved resume
      position, and plays through `FFmpegDecoder` (http) or the local decoder
      (file).
- [ ] Position is written back on the periodic tick and on pause / stop / quit;
      the per-episode position, not the global one, governs a podcast item.
- [ ] A finished episode is marked played; podcasts never scrobble.
- [ ] Now Playing media type is `.podcast`; title = episode, artist-slot = show.
- [ ] App wires `AppPodcastResolver` over `PodcastService`.
- [ ] `make test-playback` green; coverage at or above floor; no lint/format
      warnings.

## Gotchas

- **Two resume paths must not fight.** The global
  `UserDefaults["playback.resumePosition"]` restore is for the last queue
  position generally; the per-episode resume is podcast-specific. Guard the
  global path to skip podcast items so a podcast does not get double-seeked or
  seeked to a stale global value.
- **trackID sentinel.** A podcast item must not collide with a real `tracks`
  rowid. Reuse the exact convention `.subsonic` / `.internetRadio` items already
  use; any `Track`-by-id lookup in the player already has to tolerate non-local
  items, so route podcasts through the same branch.
- **Position spam.** Writing every 5 s is fine; do not write on every engine
  progress callback (sub-second). The existing 5 s history tick is the right
  cadence; reuse it.
- **markPlayed idempotency.** Both the natural-end path here and the
  near-end-position path in 21-4 can fire; both are idempotent upserts, so a
  double call is harmless. Do not add guard logic that makes one path skip the
  other.
- **Gapless across episodes.** Queuing several episodes is allowed; the
  `GaplessScheduler` will try to pre-stage the next item. Position write-back and
  mark-played must still fire on the gapless transition (handle it in the
  gapless-transition handler, not only `handleTrackEnded`).
- **Speed (rate) and pitch.** Phase 21-10 adds a speed control via the existing
  `setRate`. Verify the engine's rate path preserves pitch (time-stretch, not
  varispeed); if it chipmunks at 1.5x, that is a small AudioEngine fix flagged
  there, not here.
- **`Playback` must not import `Subsonic` or `Podcasts`.** The resolver protocol
  is the only contact surface; widen the protocol if the player needs more, never
  add a module import (per the Playback CLAUDE.md).

## Handoff

Phase 21-9's episode rows build the podcast `QueueItem` per the field contract
above and call the existing `QueuePlayer` play APIs. Phase 21-10 adds the
podcast Now-Playing rendering and the speed/skip controls over `setRate` /
`seek`. Phase 21-6's downloads make `resolver.audioURL` return a local file when
present, upgrading streamed seeking to local-file seeking with no player change.
