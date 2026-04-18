# Bòcan — Phase Specs

One file per phase. Point a fresh Claude Code / Copilot session at a single file and let it work. Do not skip ahead; phases are dependency-ordered.

## How to use

1. Open a **fresh session** per phase (keeps context lean).
2. Tell the assistant: *"Read `phases/phase-NN-<name>.md` and `phases/_standards.md`. Implement exactly what is specified. Use Context7 for every listed lookup. Write tests as you go. Commit with Conventional Commits. Stop when every acceptance-criteria box is checked."*
3. Run `make lint && make test-coverage` before declaring the phase done.
4. Open a PR. Only move to the next phase once CI is green and the checklist is fully ticked.

## Files

| Phase | File | Output |
|---|---|---|
| — | [_standards.md](_standards.md) | Cross-cutting rules referenced by every phase |
| 0 | [phase-00-foundations.md](phase-00-foundations.md) | Repo, CI, Makefile, logger, empty app |
| 1 | [phase-01-audio-engine.md](phase-01-audio-engine.md) | Single-file playback, AVFoundation + FFmpeg decoders |
| 2 | [phase-02-persistence.md](phase-02-persistence.md) | GRDB + schema + repositories |
| 3 | [phase-03-library-scanning.md](phase-03-library-scanning.md) | Folder scan, TagLib, FSEvents |
| 4 | [phase-04-library-ui.md](phase-04-library-ui.md) | 3-pane browser, Table, search |
| 5 | [phase-05-queue-gapless.md](phase-05-queue-gapless.md) | Queue, gapless, MPNowPlaying |
| 6 | [phase-06-manual-playlists.md](phase-06-manual-playlists.md) | CRUD playlists |
| 7 | [phase-07-smart-playlists.md](phase-07-smart-playlists.md) | Rule builder, SQL compiler |
| 8 | [phase-08-metadata-editor.md](phase-08-metadata-editor.md) | Tag editor + cover art fetch |
| 9 | [phase-09-eq-effects.md](phase-09-eq-effects.md) | 10-band EQ, ReplayGain, crossfeed |
| 10 | [phase-10-mini-player-polish.md](phase-10-mini-player-polish.md) | Mini player, themes, dock tile |
| 11 | [phase-11-lyrics.md](phase-11-lyrics.md) | LRC + embedded lyrics |
| 12 | [phase-12-visualizers.md](phase-12-visualizers.md) | FFT + Metal/Canvas visualizers |
| 13 | [phase-13-scrobbling.md](phase-13-scrobbling.md) | Last.fm + ListenBrainz |
| 14 | [phase-14-playlist-import-export.md](phase-14-playlist-import-export.md) | M3U/M3U8/PLS/XSPF |
| 15 | [phase-15-casting.md](phase-15-casting.md) | AirPlay 2 + Google Cast |
| 16 | [phase-16-distribution.md](phase-16-distribution.md) | Sign, notarize, DMG, Sparkle |

## Conventions used in every phase file

- **Prerequisites** — what must already exist
- **Goal / Non-goals** — keep scope honest
- **Implementation plan** — ordered, small, committable steps
- **Definitions & contracts** — types/protocols/SQL the assistant should produce verbatim
- **Context7 lookups** — drop these into prompts
- **Dependencies** — exact SPM / Homebrew additions
- **Test plan** — specific cases, not vibes
- **Acceptance criteria** — checklist to tick before merging
- **Gotchas** — the things that will bite you, named in advance
- **Handoff** — what the next phase expects
