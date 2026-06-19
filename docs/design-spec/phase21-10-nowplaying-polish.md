# Phase 21-10: Podcasts - Now Playing podcast mode, transport, settings, docs

> Depends on: `phase21-0-overview.md`, `phase21-5-playback.md` (the `.podcast`
> source + podcast Now Playing metadata; note there is no `.podcast` media type,
> so detect podcasts via `PlayableSource.podcast`),
> `phase21-7-ui-podcasts-home.md` (seams + view model),
> `phase21-9-ui-episodes.md` (the play surface). Phase 21-6 informs the settings
> (downloads) but is not required. Touches **UI** and **App**.
>
> Provides: the Now Playing / mini player "podcast mode" (show art, episode
> title, show name), podcast transport (skip-back/skip-forward + playback speed),
> a Podcasts settings pane, the localization sweep, accessibility pass, and the
> README / website / NOTICES documentation.

## Goal

Make the playing episode feel native by reusing the existing Now Playing chrome
with adapted metadata (the brief's "minimal UI change, maximum reuse"), add the
two transport affordances podcasts need (skip intervals and speed), and finish
the feature with settings, localization, accessibility, and docs.

## Now Playing podcast mode

The Now Playing strip (`AppRoot/NowPlayingStrip.swift`) and
`NowPlayingViewModel` already render artwork / title / artist / album with
click-throughs. Adapt, do not duplicate.

### NowPlayingViewModel

Add a podcast flag + identity so the view can branch and the click-throughs can
target the show:

```swift
@Published public private(set) var isPodcast = false
@Published public private(set) var podcastID: Int64?         // podcasts.id, for "go to show"
@Published public private(set) var podcastFeedURL: URL?
@Published public private(set) var podcastGUID: String?
```

When the current item is a podcast (the player exposes the current
`PlayableSource`, or the App sets this when it enqueues the episode), populate:

- `artwork` = the show's cached artwork (the existing artwork resolution already
  takes a path/URL; feed it the show `artwork_path`, with episode art override
  when present).
- `title` = episode title (already carried by the `QueueItem.title`).
- `artist` = show name (already carried by `QueueItem.artistName`, per the phase
  21-5 field contract, so the artist slot shows the show with **no new
  plumbing**).
- `album` = optional: the publish date or show name; can stay empty.

Because the `QueueItem` already carries episode-as-title and show-as-artist, the
strip mostly "just works"; the flag exists so click-throughs and transport
differ.

### NowPlayingStrip

Branch on `vm.isPodcast`:

- **Artwork click** -> go to the show (`library.selectDestination(.podcastShow(
  vm.podcastID!))`) instead of `goToCurrentAlbum`.
- **Title click** -> scroll to / select the episode in the show list (or no-op if
  not on that show).
- **Artist-slot click** -> also go to the show (there is no separate "artist").
- Hide music-only affordances that do not apply (e.g. "go to album artist") and
  surface the podcast transport (below) in their place.

Keep the layout identical; only swap targets and the transport cluster. The mini
player (`MiniPlayer/`) mirrors the same branch (show art + episode title; tapping
goes to the show).

## Podcast transport

Two podcast-specific controls, both built on existing engine APIs (no engine
change beyond verifying rate-preserves-pitch):

### Skip intervals

Replace (or augment) prev/next with **skip-back** and **skip-forward** when
`isPodcast`:

- Skip back: `seek(to: max(0, currentTime - backInterval))`, default 15 s.
- Skip forward: `seek(to: min(duration, currentTime + forwardInterval))`, default
  30 s.
- Wire these to the `MPRemoteCommandCenter` skip commands too
  (`skipBackwardCommand` / `skipForwardCommand` with `preferredIntervals`), so
  lock-screen / AirPods / media keys do podcast-appropriate skips while a podcast
  plays, and revert to prev/next for music. (Drive this off `isPodcast` /
  `PlayableSource.podcast`, the same signal phase 21-5 uses; there is no
  `.podcast` Now Playing media type to switch on.)
- Intervals are settings (below); default 15 / 30.

### Playback speed

A speed control (`0.8x / 1.0x / 1.25x / 1.5x / 1.75x / 2.0x`) shown when
`isPodcast`. It maps to the existing `QueuePlayer.setRate(_:)`.

- **Verify the engine's rate path preserves pitch** (time-stretch, not
  varispeed). If `setRate` currently chipmunks the audio, add pitch correction in
  AudioEngine (an `AVAudioUnitTimePitch`, or set the player node's
  time-pitch algorithm) so 1.5x speech stays natural. This is the one possible
  AudioEngine touch in the whole feature; scope it small and test at 0.8x/1.5x/2x.
- Persist the last podcast speed (per-show optional; global is fine for MVP) and
  reapply when a podcast starts. Music playback keeps its own rate (usually 1.0);
  do not let the podcast speed leak into music.

## Podcasts settings pane

Add a Podcasts section to the Settings scene (the System-Settings-style
`Settings/` TabView), placed near Playback/Library. Fields:

| Setting | Control | Default |
|---------|---------|---------|
| Refresh interval | every 15 / 30 / 60 min, or manual | 30 min |
| Refresh on launch | toggle | on |
| Auto-download newest N (per flagged show) | stepper 1..5 | 3 |
| Skip-back interval | 10 / 15 / 30 s | 15 s |
| Skip-forward interval | 15 / 30 / 45 s | 30 s |
| Default playback speed | 0.8..2.0x | 1.0x |
| Mark as played at | 90 / 95 / 100% (the completion tail) | within 15 s of end |
| Downloads location size + "Clear downloads" | read-only size + button | - |
| Auto-delete played downloads after | off / 1 / 7 / 30 days | off |
| Search storefront country | picker | US |
| Podcast Index | status: configured / not configured | - |

These persist via the existing settings repository. The refresh interval feeds
`FeedRefreshScheduler` (phase 21-4); the download settings feed phase 21-6 (hide
the download rows cleanly if 21-6 is not built); skip/speed/mark-played feed the
transport + the shared completion constant.

## Localization sweep

Per the UI CLAUDE.md and `docs/design-spec/localization.md`:

- Every string added across phases 21-7 to 21-10 (sidebar label, Add bar prompt,
  empty states, badge/source labels, detail buttons, column headers, status
  labels, context menus, settings labels, toasts, errors) goes through `L10n`
  with a key in `Modules/UI/Sources/UI/Resources/Localizable.xcstrings`.
- Run `make pseudolocale` after the final key additions; `L10nTests` must pass
  (every key has an `en-XA` variant ~30% longer, format specifiers survive).
- Lower-module status strings displayed in the UI (e.g. download-state labels
  owned conceptually by `Podcasts`) keep raw English values and get a **UI-side
  display mapping** (like the Subsonic `SubmissionStatus` precedent); do not
  localize the `Podcasts` module.
- Feed content (titles/authors/notes) stays verbatim.
- Manual check: launch with `-AppleLanguages '(en-XA)'` and confirm all podcast
  chrome is accented (a plain-English string is a missed conversion) and nothing
  clips under ~30% expansion.

## Accessibility pass

- The status indicator already differs by shape (phase 21-9); confirm VoiceOver
  reads "Unplayed / In progress / Played" and the row encodes remaining time.
- Skip/speed controls have `accessibilityLabel`s ("Skip back 15 seconds",
  "Playback speed 1.5x").
- Full keyboard navigation through the Add bar, results, detail, grid, and
  episode table (no mouse-only actions, per standards).
- Source badges carry the source(s) in their label (phase 21-8).

## Docs

Per the root CLAUDE.md ("Document new features in README.md and in the repo's
/website pages"):

- `README.md`: add Podcasts to the feature list (subscribe by URL or search
  across Podcast Index + Apple, RSS + Atom, per-episode resume, downloads,
  speed/skip).
- `/website` pages: add a Podcasts feature section/screenshots consistent with
  the existing feature pages. **No em dashes / en dashes** in README or website
  copy (root rule).
- Help Book (`HelpBook/`): a short "Podcasts" topic (how to add, subscribe,
  download, resume) under Bòcan Music Help, matching how Subsonic was documented.
- `NOTICES.md`: ensure FeedKit (phase 21-2) is listed with its license. Note the
  use of the Podcast Index and Apple iTunes Search APIs (attribution as their
  terms require).
- `docs/design-spec/README.md`: the Phase 21 rows are added (this spec set does
  that; verify they are present).

## Context7 lookups

- Apple `MediaPlayer`: `MPRemoteCommandCenter.skipForwardCommand` /
  `skipBackwardCommand`, `preferredIntervals`. Switch command behaviour by the
  `isPodcast` / `PlayableSource.podcast` signal, not by Now Playing media type
  (there is no `.podcast` media-type member).
- AVFoundation: `AVAudioUnitTimePitch` / player-node rate with pitch correction
  for the speed control (verify the existing engine rate path).

## Test plan

- **NowPlayingViewModel** podcast mode: setting a podcast current item sets
  `isPodcast`, `podcastID`, title=episode, artist=show; clearing to a music track
  resets the flag.
- **Skip**: skip-back/forward compute clamped seek targets; speed maps to
  `setRate` and persists/reapplies for podcasts only.
- **NowPlayingStrip** snapshot in podcast mode (show art + episode + show name),
  light + dark; click-throughs target the show.
- **Settings**: values persist and round-trip; the refresh interval reaches the
  scheduler; download rows hidden when 21-6 absent.
- **Speed/pitch** integration: at 1.5x the output is time-stretched (pitch
  preserved) - assert via the engine's configured time-pitch algorithm, or a
  manual verification note if it cannot be unit-tested host-less.
- **L10n**: full `en-XA` coverage for all new keys; `make pseudolocale` run;
  `L10nTests` green.
- `make test-ui` (snapshots + view-model + source-convention) is the final gate.

## Acceptance criteria

- [ ] Now Playing and the mini player show the playing episode in podcast mode:
      show artwork, episode title, show name; click-throughs go to the show.
- [ ] Skip-back / skip-forward controls (default 15 / 30 s) work in-app and via
      the lock-screen / media-key remote commands while a podcast plays.
- [ ] A playback-speed control maps to `setRate`, preserves pitch, persists for
      podcasts, and does not affect music playback.
- [ ] A Podcasts settings pane exposes refresh interval, auto-download N, skip
      intervals, default speed, mark-played threshold, storefront, downloads
      size + clear, and Podcast Index status; values persist and drive the
      relevant subsystems.
- [ ] All podcast chrome is localized; `make pseudolocale` run; `L10nTests`
      green; `en-XA` launch shows fully accented chrome with no clipping.
- [ ] Accessibility: states differ by shape, controls are labelled, full keyboard
      nav.
- [ ] README, website, Help Book, and NOTICES updated (no em/en dashes).
- [ ] `make format && make lint && make build && make test-coverage` green; no
      lint (incl. `file_length`) or format warnings.

## Gotchas

- **Rate must preserve pitch.** Sped-up speech that chipmunks is unusable. Verify
  the engine's time-pitch algorithm before shipping the speed control; this is the
  only place the AudioEngine might need a small change in the whole feature.
- **Podcast speed must not leak into music.** Reset rate to the music default when
  switching from a podcast item to a track, and vice versa apply the saved podcast
  speed. Drive this off the `isPodcast` transition.
- **Remote-command behaviour switches with the podcast source.** When a podcast
  plays, prev/next on the lock screen should skip intervals; when music plays,
  they should change tracks. Toggle the command center config off the `isPodcast`
  / `PlayableSource.podcast` transition (not a Now Playing media type, which has
  no `.podcast` member), and restore it cleanly.
- **`NowPlayingStrip` is at the 500-line `file_length` cap** (per the UI
  CLAUDE.md). Add the podcast branch by extracting a small subview, not by
  swelling the file; do not add a `swiftlint:disable`.
- **Settings that feed lower modules** (refresh interval, completion threshold)
  must reach them through the existing injection, not a UI->Podcasts import.
- **No em/en dashes anywhere** in README, website, Help Book, commit messages
  (root rule). Use plain punctuation.

## Handoff (feature complete)

With this slice, Phase 21 is done:

- Podcasts is a native part of the Local Library: discover (dual-index search +
  add by URL), subscribe (RSS + Atom), browse (album-styled grid), listen
  (episode list with live progress), and resume (per-episode position, written
  back continuously) with downloads, speed, and skip.
- The episode-state table is the durable home for per-episode progress; future
  work (a "Continue Listening" rail, OPML import/export, chapters + transcripts,
  cross-device sync, video podcasts) builds on the `Podcasts` module and the
  `PlayableSource.podcast` plumbing without re-templating any of it.
