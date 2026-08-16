# ADR-087: CUE Sheets as In-Track Markers

> Prerequisites: ADR-030 (playlist import), ADR-053 (podcast chapters, the
> conceptual precedent), and the 2026-08 CUE hardening (issues #390, #391).
> Supersedes the virtual-track CUE design and the scanner-side sketch in
> issue #392. Informed by a real-library survey (see #392's comments): of
> ~13 cue sheets found in an actual collection, zero were single-file
> rips; all were one-FILE-per-track manifests beside already-split,
> individually-tagged files, plus stale sheets referencing transcoded-away
> audio and one folder carrying three overlapping cues.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

CUE sheets stop being track-splitting devices and become **markers on the
track they reference** — the chapters model. Music files always import as
ordinary tracks; a cue changes how the player bar looks and behaves for
its file, nothing else.

The decided behaviour:

- **Music files are always imported as normal tracks.** No monolith vs
  virtual split, ever.
- **Cues are automatically imported during scans** (and via the FSEvents
  watcher when one appears later), attaching markers to the referenced
  tracks. Automatic import never creates playlists.
- **Transport semantics for a track with more than one marker:**
  - Back: restarts the current marker when playback is past the restart
    threshold, otherwise jumps to the previous marker; at the first
    marker, behaves as today (previous track / restart).
  - Forward: jumps to the next marker; past the last marker it advances
    to the next track as today.
  - Media keys, MPRemoteCommands, and the mini player follow the same
    semantics uniformly.
- **The progress bar shows tick marks at marker positions** — a track
  with four cue points reads `|------|-----|-|----`. While inside a
  marker, the strip shows the marker's TITLE/PERFORMER as a secondary
  line (the podcast-chapter precedent; the track's own metadata stays
  primary).
- **A track with exactly one marker at 00:00 shows nothing special.**
  This makes the survey's entire pathology inert by construction: a
  one-FILE-per-track manifest yields one marker per track and disappears;
  a stale cue references no known audio and attaches nothing; overlapping
  cues dedupe per audio target.
- **Manual Import Playlist of a cue** attaches the same markers, and may
  additionally create an ordinary playlist of the *real* tracks its FILE
  entries resolve to (the m3u TrackResolver path, misses counted the
  same way). It never creates virtual tracks.

## Non-goals

- Per-marker scrobbling (a natural follow-up, deliberately out of scope:
  a single-file mix scrobbles as one play for now).
- Exposing markers at the library level: inner songs of a single-file
  rip are not browsable, queueable, or shuffleable individually. This is
  the model's accepted trade.
- Editing markers in the app (cue files remain the source of truth).

## Implementation plan

1. **Persistence.** A `track_markers` table (`track_id` FK ON DELETE
   CASCADE, `position_ms`, `title`, `performer`, `sort`), numbered
   migration, `TrackMarkerRepository`. A cleanup migration deletes the
   retired `?cue=N` virtual rows (their `file_url` LIKE pattern) and
   their playlist memberships.
2. **`CueMarkerService` (Library).** The single attach path both doors
   share: parse via `CUESheetReader`, match FILE targets against indexed
   tracks by canonical file URL, write markers per track (replace-on-
   reimport so an edited cue updates in place; a deleted cue leaves
   markers untouched — safety over symmetry). Skip FILE entries whose
   audio is missing, with a logged warning. Dedupe rule: at most one
   cue's markers per audio file; prefer the sheet whose FILE targets all
   exist, then first-seen.
3. **Scanner + watcher hooks.** During scans, a folder's `.cue` files
   are parsed after its audio is indexed (mirror of the issue-#388
   sidecar-art pattern: the FSEvents branch that heals sidecar art
   extends to sidecar cues). `TagReader.supportedExtensions` stays
   audio-only; cue discovery is a per-folder pass, not a walker entry.
4. **Playback semantics.** `NowPlayingViewModel` (and the QueuePlayer
   seam it drives) learns the current track's markers: back/forward per
   the rules above, the existing restart threshold reused, media keys
   and the mini player inheriting automatically through the shared view
   model. Marker jumps are plain seeks — no engine reload, gapless by
   construction.
5. **Scrubber ticks + marker display.** The `nowPlayingStrip.scrubber`
   gains a marker-tick overlay (hidden when the track has fewer than two
   markers); the strip shows the active marker's title/performer while
   within it.
6. **Import path rewire + retirement.** `importCUESheet` drops the
   virtual-track machinery in favour of `CueMarkerService` + the
   optional resolver playlist. The #391 access-grant flow carries over
   unchanged (markers still need readable audio to verify targets; the
   probe and folder-grant panel survive as-is). The AudioEngine segment
   primitive (`setSegment`, the BufferPump frame budget) stays — tested,
   harmless, and useful for future features — but Playback's cue-segment
   persistence fields become legacy-only.

## Test plan

- Unit: `CueMarkerService` classification against survey-shaped fixtures
  (manifest cue → one marker per track, hidden; single-file rip → N
  markers; stale cue → no-op with warning; three overlapping cues → one
  winner). Marker-aware transport in `NowPlayingViewModel` (back/forward
  at every boundary condition, restart threshold).
- Snapshot: scrubber with and without ticks; single-marker track shows
  the plain bar.
- The existing CUE E2E-era import tests migrate from virtual-track
  assertions to marker assertions.

## Acceptance criteria

- [ ] A single-file rip (audio + cue) dropped into a library root plays
      as one track with tick marks, marker-wise back/forward, and the
      current marker's title in the strip.
- [ ] A one-FILE-per-track manifest cue in a scanned folder changes
      nothing visible anywhere.
- [ ] Stale and duplicate cues attach nothing and log why.
- [ ] No `?cue=N` virtual rows exist after migration; manual cue import
      creates markers (and at most an ordinary resolved playlist).
- [ ] Media keys, mini player, and the main strip agree on marker
      navigation.

## Gotchas

- Marker positions come from `INDEX 01` at 75 fps; reuse
  `CUESheetReader.parseMSF`, never re-derive.
- The FSEvents cue-heal must not fight the mtime guard: a cue event
  re-attaches markers even when the audio is unchanged (same shape as
  the sidecar-art heal).
- The strip's marker line must not invalidate the menu bar (the
  BocanCommands plain-`let` rule); markers change at seek/tick
  granularity, so route them through the existing position publisher.
- Restart threshold: back-to-previous-marker must use the same "just
  started" window as track-back, or muscle memory breaks.

## Handoff

Issue #392 tracks implementation; per-marker scrobbling and library-level
marker browsing are explicit future ADRs if ever wanted.
