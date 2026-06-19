# Bòcan — Phase Specs

One file per phase. Point a fresh Claude Code / Copilot session at a single file and let it work. Do not skip ahead; phases are dependency-ordered.

## How to use

1. Open a **fresh session** per phase (keeps context lean).
2. Tell the assistant: *"Read `docs/design-spec/phase-NN-<name>.md` and `docs/design-spec/_standards.md`. Implement exactly what is specified. Use Context7 for every listed lookup. Write tests as you go. Commit with Conventional Commits. Stop when every acceptance-criteria box is checked."*
3. Run `make lint && make test-coverage` before declaring the phase done.
4. Open a PR. Only move to the next phase once CI is green and the checklist is fully ticked.

## Files

| Phase | File | Output |
|---|---|---|
| — | [_standards.md](_standards.md) | Cross-cutting rules referenced by every phase |
| n/a | [localization.md](localization.md) | UI string-catalog workflow, conversion recipe, regression guard (#314) |
| 0 | [phase-00-foundations.md](phase-00-foundations.md) | Repo, CI, Makefile, logger, empty app |
| 1 | [phase-01-audio-engine.md](phase-01-audio-engine.md) | Single-file playback, AVFoundation + FFmpeg decoders |
| 2 | [phase-02-persistence.md](phase-02-persistence.md) | GRDB + schema + repositories |
| 3 | [phase-03-library-scanning.md](phase-03-library-scanning.md) | Folder scan, TagLib, FSEvents |
| 4 | [phase-04-library-ui.md](phase-04-library-ui.md) | 3-pane browser, Table, search |
| 5 | [phase-05-queue-gapless.md](phase-05-queue-gapless.md) | Queue, gapless, MPNowPlaying |
| 6 | [phase-06-manual-playlists.md](phase-06-manual-playlists.md) | CRUD playlists |
| 7 | [phase-07-smart-playlists.md](phase-07-smart-playlists.md) | Rule builder, SQL compiler |
| 8 | [phase-08-metadata-editor.md](phase-08-metadata-editor.md) | Tag editor + cover art fetch |
| 8.5 | [phase-08.5-acoustid-fingerprinting.md](phase-08.5-acoustid-fingerprinting.md) | AcoustID + MusicBrainz auto-tagging |
| 9 | [phase-09-eq-effects.md](phase-09-eq-effects.md) | 10-band EQ, ReplayGain, crossfeed, crossfade |
| 10 | [phase-10-mini-player-polish.md](phase-10-mini-player-polish.md) | Mini player, themes, dock tile |
| 11 | [phase-11-lyrics.md](phase-11-lyrics.md) | LRC + embedded lyrics |
| 12 | [phase-12-visualizers.md](phase-12-visualizers.md) | FFT + Metal/Canvas visualizers |
| 12.1 | [phase-12.1-visualizer-foundations.md](phase-12.1-visualizer-foundations.md) | Analysis v2 (centroid, flux, onsets), PaletteResolver, Drift + Thermal palettes |
| 12.2 | [phase-12.2-visualizer-halo.md](phase-12.2-visualizer-halo.md) | Halo: radial spectrum ring, beat ripples |
| 12.3 | [phase-12.3-visualizer-cascade.md](phase-12.3-visualizer-cascade.md) | Cascade: scrolling spectrogram waterfall |
| 12.4 | [phase-12.4-visualizer-starfield.md](phase-12.4-visualizer-starfield.md) | Starfield: frequency-coloured warp particles (renderer superseded by 12.11) |
| 12.5 | [phase-12.5-visualizer-nebula.md](phase-12.5-visualizer-nebula.md) | Nebula: Metal gas clouds with moving wisps (plumbing superseded by 12.12) |
| 12.6 | [phase-12.6-visualizer-metal-foundations.md](phase-12.6-visualizer-metal-foundations.md) | MetalVisualizer protocol, MTKView host, shared GPU helpers |
| 12.7 | [phase-12.7-visualizer-metal-oscilloscope.md](phase-12.7-visualizer-metal-oscilloscope.md) | Oscilloscope on Metal (first conversion, pattern-setting) |
| 12.8 | [phase-12.8-visualizer-metal-cascade.md](phase-12.8-visualizer-metal-cascade.md) | Cascade on Metal (history ring buffer as GPU texture) |
| 12.9 | [phase-12.9-visualizer-metal-spectrum-bars.md](phase-12.9-visualizer-metal-spectrum-bars.md) | Spectrum Bars on Metal (instanced SDF quads) |
| 12.10 | [phase-12.10-visualizer-metal-halo.md](phase-12.10-visualizer-metal-halo.md) | Halo on Metal (CPU geometry, GPU rasterisation) |
| 12.11 | [phase-12.11-visualizer-metal-starfield.md](phase-12.11-visualizer-metal-starfield.md) | Starfield: Metal warp field (implements 12.4's design) |
| 12.12 | [phase-12.12-visualizer-metal-nebula.md](phase-12.12-visualizer-metal-nebula.md) | Nebula on the 12.6 foundations (delta over 12.5) |
| 13 | [phase-13-scrobbling.md](phase-13-scrobbling.md) | Last.fm + ListenBrainz |
| 14 | [phase-14-playlist-import-export.md](phase-14-playlist-import-export.md) | M3U/M3U8/PLS/XSPF |
| 15 | [phase-15-casting.md](phase-15-casting.md) | AirPlay 2 + Google Cast |
| 16 | [phase-16-distribution.md](phase-16-distribution.md) | Sign, notarize, DMG, Sparkle |
| 18 | [phase-18-remote-control.md](phase-18-remote-control.md) | Remote control server — Bonjour discovery, PIN pairing, REST/WebSocket API |
| 19 | [phase-19-subsonic.md](phase-19-subsonic.md) | Subsonic / Navidrome / OpenSubsonic client — sidebar "Sources" section, federated search, streaming cache, write-through annotations |
| 20 | [phase-20-console.md](phase-20-console.md) | In-app log console backed by `LogStore` |
| 21.0 | [phase21-0-overview.md](phase21-0-overview.md) | Podcasts: architecture, data model, cross-phase contract (read first) |
| 21.1 | [phase21-1-persistence.md](phase21-1-persistence.md) | Podcasts: schema (3 tables), records, repositories |
| 21.2 | [phase21-2-feeds.md](phase21-2-feeds.md) | Podcasts: module scaffold, feed fetch, RSS + Atom parsing |
| 21.3 | [phase21-3-search.md](phase21-3-search.md) | Podcasts: Podcast Index + iTunes dual search, dedupe/merge |
| 21.4 | [phase21-4-subscriptions.md](phase21-4-subscriptions.md) | Podcasts: `PodcastService` subscribe/refresh/state, artwork cache |
| 21.5 | [phase21-5-playback.md](phase21-5-playback.md) | Podcasts: `PlayableSource.podcast`, resolver seam, per-episode resume |
| 21.6 | [phase21-6-downloads.md](phase21-6-downloads.md) | Podcasts: episode downloads + offline (enhancement) |
| 21.7 | [phase21-7-ui-podcasts-home.md](phase21-7-ui-podcasts-home.md) | Podcasts UI: sidebar item, subscribed grid, Add bar, UI seams |
| 21.8 | [phase21-8-ui-search-detail.md](phase21-8-ui-search-detail.md) | Podcasts UI: search results (source badges), detail, Subscribe |
| 21.9 | [phase21-9-ui-episodes.md](phase21-9-ui-episodes.md) | Podcasts UI: episode list (date/duration/progress), show notes |
| 21.10 | [phase21-10-nowplaying-polish.md](phase21-10-nowplaying-polish.md) | Podcasts: Now Playing podcast mode, speed/skip, settings, docs |

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
