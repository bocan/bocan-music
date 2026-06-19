# Phase 21-6: Podcasts - Episode downloads and offline playback (enhancement)

> Depends on: `phase21-0-overview.md`, `phase21-1-persistence.md`,
> `phase21-4-subscriptions.md`. **Optional / post-MVP.** Streaming works without
> it; this slice adds offline downloads, which also give rock-solid seek and
> resume. Touches **Podcasts** (the download manager + state) and **App** (start
> the manager); the player needs no change because `PodcastService.audioURL`
> already prefers a downloaded file (phase 21-4).
>
> Provides: `EpisodeDownloadManager`, download progress, auto-download, storage
> management, and offline playback (via the existing resolver path).

## Goal

Let the user download an episode for offline listening and reliable seeking, show
download state in the episode list, optionally auto-download the newest episodes
of selected shows, and keep disk usage bounded. Playback automatically uses a
downloaded file when one exists (already wired in 21-4's `audioURL`).

## Non-goals

- No download of show artwork (that is `PodcastArtworkCache`, phase 21-4).
- No streaming-while-downloading. A partially downloaded file is not played; the
  resolver returns the enclosure URL until the download completes (mirrors the
  Subsonic "fully buffered before ready" rule for the same `AVAudioFile`-snapshot
  reason, though podcasts use `FFmpegDecoder` for streaming).
- No background (out-of-process) downloads continuing after the app quits. A
  download in flight at quit is paused (resume data saved) and resumed next
  launch. (A true `URLSession` background configuration is a later nicety.)

## Outcome shape

```
Modules/Podcasts/Sources/Podcasts/
├── Downloads/
│   ├── EpisodeDownloadManager.swift     # actor: queue, progress, pause/resume/cancel
│   ├── DownloadStore.swift              # on-disk layout + path helpers
│   └── Models/
│       └── EpisodeDownload.swift        # progress/status value type for the UI
```

## `EpisodeDownloadManager`

```swift
public actor EpisodeDownloadManager {
    public init(stateRepo: EpisodeStateRepository,
                episodeRepo: EpisodeRepository,
                store: DownloadStore = .init(),
                session: URLSession = .shared)

    /// Enqueue a download. Sets state -> queued, then downloading. Idempotent:
    /// a second call for an in-flight or completed episode is a no-op.
    public func download(podcastID: Int64, guid: String) async

    public func cancel(podcastID: Int64, guid: String) async        // -> state none, delete partial
    public func pause(podcastID: Int64, guid: String) async         // keep resume data
    public func removeDownload(podcastID: Int64, guid: String) async // -> state none, delete file

    /// Live progress for the UI. Emits (podcastID, guid, fractionComplete,
    /// bytesWritten, totalBytes, status).
    public nonisolated var progress: AsyncStream<EpisodeDownload> { get }

    /// On launch: resume any episode whose state is `.downloading`/`.queued`
    /// (interrupted by a prior quit) using saved resume data when available.
    public func resumeInterrupted() async

    public func totalBytesOnDisk() async -> Int64
    public func clearAll() async                                    // delete every download, reset state
}
```

Behaviour:

- Concurrency cap (e.g. 2 simultaneous downloads); the rest sit in `.queued`.
- Use `URLSessionDownloadTask`; on completion move the temp file into
  `DownloadStore`'s final path and `stateRepo.setDownloadState(.downloaded,
  path:, bytes:)`. On failure, `.failed` (with a retry affordance in the UI).
- Pause uses `cancel(byProducingResumeData:)`; store the resume data (in memory,
  or a sidecar file) so resume continues rather than restarts.
- `try Task.checkCancellation()` and cooperative cancellation throughout.
- 60 s resource timeout per task; episodes can be large, so do not cap total
  duration, only idle time.
- Emit `progress` at a throttled cadence (e.g. on each delegate callback but no
  more than ~4/s per task) so the UI list does not thrash.

## `DownloadStore`

On-disk layout under Application Support (downloads are user data the user
expects to persist, not a cache the OS may purge):

```
~/Library/Application Support/Bocan/Podcasts/Downloads/<podcastID>/<guidHash>.<ext>
```

- `<guidHash>` = a stable hash of the guid (guids can contain `/`, URLs, etc.;
  never use the raw guid as a filename).
- `<ext>` from the enclosure MIME / URL extension; default `.mp3`.
- Helpers: `fileURL(podcastID:guid:mime:)`, `exists(...)`, `delete(...)`,
  `bytes(...)`, `deletePodcast(podcastID:)` (called by `unsubscribe`).
- Excluded from the user's iCloud/Time Machine is unnecessary; standard
  Application Support is fine.

## Auto-download

- `podcasts.auto_download` (already in the schema) gates it. When a `refresh`
  (phase 21-4) discovers new episodes for an auto-download show, enqueue the
  newest **N** (a setting, default 3) that are not already downloaded or played.
- Hook: `PodcastService.refresh` returns the new episodes; the App layer (or a
  small coordinator in the Podcasts module) calls
  `downloadManager.download(...)` for the qualifying ones. Keep the
  decision-making out of the bare download manager.

## Storage management

- A global "downloads" budget setting (default e.g. 5 GB) shown in the Podcasts
  settings pane (phase 21-10). When exceeded, evict **played + downloaded**
  episodes oldest-first; never evict an unplayed or in-progress download
  automatically.
- An "auto-delete played downloads after N days" setting (default off) for shows
  the user finishes.
- `clearAll()` and per-show "Remove all downloads" for manual cleanup.

## Offline playback

No player change needed: `PodcastService.audioURL` (phase 21-4) already returns
the downloaded `file://` URL when `state.downloadState == .downloaded` and the
file exists, else the enclosure URL. A downloaded episode therefore decodes via
the local-file path (`AVFoundationDecoder` for mp3/m4a), giving exact seek and
resume even with no network. Confirm `resumePosition` + seek-on-load (phase 21-5)
work against a local file in an integration test.

## Context7 lookups

- Apple `URLSession`: `URLSessionDownloadTask`, `downloadTask(withResumeData:)`,
  `cancel(byProducingResumeData:)`, delegate progress callbacks, and (for a
  future enhancement) background `URLSessionConfiguration`.
- `FileManager`: atomic move from the download temp URL into Application Support.

## Dependencies

None new.

## Test plan

No real network: use a `URLProtocol` stub that streams fixture bytes with a
known length, or inject a session whose download task is faked. Use a temp
`DownloadStore` root.

- A queued download transitions `queued -> downloading -> downloaded`, writes the
  file, and stores path + bytes in state.
- `progress` emits monotonically increasing `fractionComplete`, ending at 1.0.
- Pause then resume continues (assert it does not redownload from 0 when resume
  data is present); cancel deletes the partial and resets state to `none`.
- `removeDownload` deletes the file and resets state; `audioURL` then returns the
  enclosure URL again.
- Concurrency cap holds (a third enqueue waits while two run).
- `resumeInterrupted` re-queues an episode left in `.downloading`.
- Eviction removes played+downloaded oldest-first and never touches unplayed.
- `unsubscribe` (phase 21-4) deletes the show's download directory (cross-check
  by calling `DownloadStore.deletePodcast`).

## Acceptance criteria

- [ ] Episodes can be downloaded, paused, resumed, cancelled, and removed; state
      and on-disk file stay consistent.
- [ ] `progress` drives a live UI indicator without thrashing.
- [ ] Downloaded episodes play and seek offline via the existing resolver path.
- [ ] Auto-download enqueues the newest N for flagged shows on refresh.
- [ ] Storage budget + auto-delete-played evict only safe episodes; `clearAll`
      and per-show removal work.
- [ ] `make test-podcasts` green; coverage at or above floor; no lint/format
      warnings.

## Gotchas

- **Never play a partial file.** A half-written enclosure decodes to a truncated
  episode (the same class of bug the Subsonic cache guards against). Only flip to
  `.downloaded` after the file is fully written and moved into place; until then
  `audioURL` returns the stream URL.
- **Guids are not filenames.** Hash them. A raw guid can be a URL with slashes.
- **Downloads are user data, not cache.** Put them in Application Support, not
  Caches, so macOS does not purge a downloaded-for-a-flight episode under disk
  pressure. The budget eviction is the app's own, deliberate policy.
- **Resume data can be nil.** Some servers do not support range resume; fall back
  to a fresh download and log it.
- **Eviction safety.** Auto-eviction must never delete an unplayed or in-progress
  download; that is the user's queued listening. Only played+downloaded are fair
  game, oldest first, and only when over budget.
- **State, not the file, is the source of truth for the UI badge,** but verify
  the file actually exists in `audioURL` (a user may have cleared
  Application Support out-of-band); if the state says downloaded but the file is
  gone, reset state to `.none` and stream.

## Handoff

Phase 21-9's episode rows show the download badge/affordance and call
`download` / `removeDownload`. Phase 21-10's settings pane surfaces the storage
budget, auto-download N, and "clear downloads". The player (21-5) is unchanged;
offline is purely a resolver-returns-a-file effect.
