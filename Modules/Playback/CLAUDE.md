# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Playback` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

The queue and "what plays next" logic, layered on top of `AudioEngine`'s `Transport`. The spine is the `QueuePlayer` actor.

- `QueuePlayer.swift` drives playback. It holds the stored state, `init` and the transport; the rest of the actor is in `QueuePlayer+*.swift` extensions by topic (`+QueueOperations`, `+Loading`, `+URLResolution`, `+EngineState`, `+Gapless`, `+Persistence`, `+RemoteCommands`), so members an extension needs are internal, not private. `PlaybackQueue.swift` holds the ordered items, history, and shuffle state. `QueueItem.swift` is the queued unit and `PlayableSource.swift` is its origin discriminator: `.localBookmark` / `.subsonic` / `.internetRadio` / `.podcast` / `.jellyfin`. A `.podcast` item resolves through the App-injected `PodcastEpisodeResolving`; Playback never imports `Podcasts`.
- `Gapless/` (`GaplessScheduler`, `CrossfadeScheduler`, `FormatBridge`) pre-schedules the next track for seamless transitions. `Shuffle/` holds the strategies (`FisherYatesShuffle`, `SmartShuffle`).
- `NowPlaying/` integrates `MPNowPlayingInfoCenter` and remote commands. `Persistence/QueuePersistence.swift` saves/restores the queue (schema v1 -> v2). `SleepTimer.swift` and `History/PlayHistoryRecorder.swift` round it out.
- `SubsonicStreamResolving.swift` is a protocol seam: Playback never imports `Subsonic`; the App layer injects a resolver that turns a `.subsonic` source into a playable URL. `JellyfinStreamResolving.swift` is its twin for `.jellyfin` (ADR-097), and Playback never imports `Jellyfin` either.

## Things easy to get wrong

- **`PlayableSource` is `Codable` with a discriminator key**, and `QueuePersistence` depends on that encoding. Adding a case means adding both encode/decode arms, handling it in the v1->v2 (or a new) persistence migration, and updating the existing persistence tests. A build that meets a kind it does not know drops that one item on restore and keeps the rest (`LenientQueueItemV2`); builds from before ADR-097 slice 5 lose the whole queue instead.
- **Do not `import Subsonic` here.** A `.subsonic` item is resolved through `SubsonicStreamResolving`; if you need more from a server, widen that protocol and let the App adapter implement it.
- Long observation/scheduler loops use `Task.checkCancellation()` and are cancelled when the queue or player tears down.

## Testing

Run `make test-playback` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/Playback`, or `make test-coverage`), run `make test-playback` last so the full module suite is the final gate before the commit.
