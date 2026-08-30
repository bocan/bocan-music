# Bòcan Design Docs

Architecture decision records (ADRs) for Bòcan, numbered in dependency order. Each ADR captures the design for one subsystem or feature slice: prerequisites, goals, contracts, test plan, and acceptance criteria. Later ADRs assume earlier ones are in place.

Cross-cutting engineering rules live in [_standards.md](_standards.md) and bind every ADR. The UI localization workflow lives in [localization.md](localization.md). Two sub-series have their own folders: [accessibility/](accessibility/) and [maintainability-audit/](maintainability-audit/).

## Index

| ADR | Covers |
|---|---|
| [ADR-001-foundations.md](ADR-001-foundations.md) | Repo, CI, Makefile, logger, empty app |
| [ADR-002-audio-engine.md](ADR-002-audio-engine.md) | Single-file playback, AVFoundation + FFmpeg decoders |
| [ADR-003-persistence.md](ADR-003-persistence.md) | GRDB + schema + repositories |
| [ADR-004-library-scanning.md](ADR-004-library-scanning.md) | Folder scan, TagLib, FSEvents |
| [ADR-005-library-ui.md](ADR-005-library-ui.md) | 3-pane browser, Table, search |
| [ADR-006-queue-gapless.md](ADR-006-queue-gapless.md) | Queue, gapless, MPNowPlaying |
| [ADR-007-add-files.md](ADR-007-add-files.md) | Add Files / Add Folder import flows |
| [ADR-008-manual-playlists.md](ADR-008-manual-playlists.md) | CRUD playlists |
| [ADR-009-smart-playlists.md](ADR-009-smart-playlists.md) | Rule builder, SQL compiler |
| [ADR-010-metadata-editor.md](ADR-010-metadata-editor.md) | Tag editor + cover art fetch |
| [ADR-011-acoustid-fingerprinting.md](ADR-011-acoustid-fingerprinting.md) | AcoustID + MusicBrainz auto-tagging |
| [ADR-012-identify-metadata-depth.md](ADR-012-identify-metadata-depth.md) | Identify flow: deeper MusicBrainz metadata, release picker |
| [ADR-013-eq-effects.md](ADR-013-eq-effects.md) | 10-band EQ, ReplayGain, crossfeed, crossfade |
| [ADR-014-mini-player-polish.md](ADR-014-mini-player-polish.md) | Mini player, themes, dock tile |
| [ADR-015-lyrics.md](ADR-015-lyrics.md) | LRC + embedded lyrics |
| [ADR-016-visualizers.md](ADR-016-visualizers.md) | FFT + Metal/Canvas visualizers |
| [ADR-017-visualizer-foundations.md](ADR-017-visualizer-foundations.md) | Analysis v2 (centroid, flux, onsets), PaletteResolver, Drift + Thermal palettes |
| [ADR-018-visualizer-halo.md](ADR-018-visualizer-halo.md) | Halo: radial spectrum ring, beat ripples |
| [ADR-019-visualizer-cascade.md](ADR-019-visualizer-cascade.md) | Cascade: scrolling spectrogram waterfall |
| [ADR-020-visualizer-starfield.md](ADR-020-visualizer-starfield.md) | Starfield: frequency-coloured warp particles (renderer superseded by ADR-027) |
| [ADR-021-visualizer-nebula.md](ADR-021-visualizer-nebula.md) | Nebula: Metal gas clouds with moving wisps (plumbing superseded by ADR-028) |
| [ADR-022-visualizer-metal-foundations.md](ADR-022-visualizer-metal-foundations.md) | MetalVisualizer protocol, MTKView host, shared GPU helpers |
| [ADR-023-visualizer-metal-oscilloscope.md](ADR-023-visualizer-metal-oscilloscope.md) | Oscilloscope on Metal (first conversion, pattern-setting) |
| [ADR-024-visualizer-metal-cascade.md](ADR-024-visualizer-metal-cascade.md) | Cascade on Metal (history ring buffer as GPU texture) |
| [ADR-025-visualizer-metal-spectrum-bars.md](ADR-025-visualizer-metal-spectrum-bars.md) | Spectrum Bars on Metal (instanced SDF quads) |
| [ADR-026-visualizer-metal-halo.md](ADR-026-visualizer-metal-halo.md) | Halo on Metal (CPU geometry, GPU rasterisation) |
| [ADR-027-visualizer-metal-starfield.md](ADR-027-visualizer-metal-starfield.md) | Starfield: Metal warp field (implements ADR-020's design) |
| [ADR-028-visualizer-metal-nebula.md](ADR-028-visualizer-metal-nebula.md) | Nebula on the ADR-022 foundations (delta over ADR-021) |
| [ADR-029-scrobbling.md](ADR-029-scrobbling.md) | Last.fm + ListenBrainz |
| [ADR-030-playlist-import-export.md](ADR-030-playlist-import-export.md) | M3U/M3U8/PLS/XSPF |
| [ADR-031-casting.md](ADR-031-casting.md) | AirPlay 2 + Google Cast |
| [ADR-032-distribution.md](ADR-032-distribution.md) | Sign, notarize, DMG, Sparkle |
| [ADR-033-trunk-based-cicd.md](ADR-033-trunk-based-cicd.md) | Trunk-based development and a small, guarded CI/CD (in progress) |
| [ADR-034-remote-control.md](ADR-034-remote-control.md) | Remote control server: Bonjour discovery, PIN pairing, REST/WebSocket API |
| [ADR-035-subsonic.md](ADR-035-subsonic.md) | Subsonic / Navidrome / OpenSubsonic client: sidebar "Sources" section, federated search, streaming cache, write-through annotations |
| [ADR-036-console.md](ADR-036-console.md) | In-app log console backed by `LogStore` |
| [ADR-037-podcasts.md](ADR-037-podcasts.md) | Podcasts: architecture, data model, cross-ADR contract (read first) |
| [ADR-038-podcast-persistence.md](ADR-038-podcast-persistence.md) | Podcasts: schema (3 tables), records, repositories |
| [ADR-039-podcast-feeds.md](ADR-039-podcast-feeds.md) | Podcasts: module scaffold, feed fetch, RSS + Atom parsing |
| [ADR-040-podcast-search.md](ADR-040-podcast-search.md) | Podcasts: Podcast Index + iTunes dual search, dedupe/merge |
| [ADR-041-podcast-subscriptions.md](ADR-041-podcast-subscriptions.md) | Podcasts: `PodcastService` subscribe/refresh/state, artwork cache |
| [ADR-042-podcast-playback.md](ADR-042-podcast-playback.md) | Podcasts: `PlayableSource.podcast`, resolver seam, per-episode resume |
| [ADR-043-podcast-downloads.md](ADR-043-podcast-downloads.md) | Podcasts: episode downloads + offline |
| [ADR-044-ui-podcasts-home.md](ADR-044-ui-podcasts-home.md) | Podcasts UI: sidebar item, subscribed grid, Add bar, UI seams |
| [ADR-045-ui-search-detail.md](ADR-045-ui-search-detail.md) | Podcasts UI: search results (source badges), detail, Subscribe |
| [ADR-046-ui-episodes.md](ADR-046-ui-episodes.md) | Podcasts UI: episode list (date/duration/progress), show notes |
| [ADR-047-nowplaying-polish.md](ADR-047-nowplaying-polish.md) | Podcasts: Now Playing podcast mode, speed/skip, settings, docs |
| [ADR-048-feedkit-upgrade.md](ADR-048-feedkit-upgrade.md) | FeedKit 9 to 10 upgrade, Sendable models |
| [ADR-049-podcast-features.md](ADR-049-podcast-features.md) | Podcasting 2.0 feature set: contract for ADR-050 to ADR-058 |
| [ADR-050-namespace-supplement.md](ADR-050-namespace-supplement.md) | Supplementary parser for the `podcast:` namespace |
| [ADR-051-transcripts.md](ADR-051-transcripts.md) | Episode transcripts (viewer, download, cleanup) |
| [ADR-052-funding.md](ADR-052-funding.md) | Podcast funding links |
| [ADR-053-chapters.md](ADR-053-chapters.md) | Podcast chapters (list + Now Playing integration) |
| [ADR-054-continue-listening.md](ADR-054-continue-listening.md) | Continue Listening shelf |
| [ADR-055-unread-badges.md](ADR-055-unread-badges.md) | Unplayed-episode badges |
| [ADR-056-opml.md](ADR-056-opml.md) | OPML subscription import/export |
| [ADR-057-per-show-settings.md](ADR-057-per-show-settings.md) | Per-show playback + refresh settings |
| [ADR-058-guid-identity.md](ADR-058-guid-identity.md) | Podcast GUID identity + migration |
| [ADR-059-podcast-notes.md](ADR-059-podcast-notes.md) | Podcast follow-up notes (FeedKit scoping history) |
| [ADR-060-phone-sync.md](ADR-060-phone-sync.md) | Phone Sync server: contract, module DAG, security model, shared fixtures (read first) |
| [ADR-061-pairing-code.md](ADR-061-pairing-code.md) | Phone Sync: `PairingCode` + golden vectors (test-first, cross-repo proof) |
| [ADR-062-identity-trust.md](ADR-062-identity-trust.md) | Phone Sync: `ServerIdentity` (Keychain P-256), `TrustedDevices`, migration M031 |
| [ADR-063-http-listener.md](ADR-063-http-listener.md) | Phone Sync: HTTP/1.1 parser, `Router`, `NWListener` TLS verify block, `/v1/ping` |
| [ADR-064-pairing-ceremony.md](ADR-064-pairing-ceremony.md) | Phone Sync: `PairingSession` state machine, `/v1/pair/*`, rate limits, `pm` hygiene |
| [ADR-065-manifest.md](ADR-065-manifest.md) | Phone Sync: `SyncProfile`, `ManifestBuilder`, generation counter + change observer |
| [ADR-066-file-serving.md](ADR-066-file-serving.md) | Phone Sync: file/artwork/lyrics/chapters serving, Range + If-Match, `SecurityScope` |
| [ADR-067-lifecycle-bonjour.md](ADR-067-lifecycle-bonjour.md) | Phone Sync: `SyncServer` actor lifecycle, Bonjour advertising, app wiring, sleep/wake |
| [ADR-068-settings-ui.md](ADR-068-settings-ui.md) | Phone Sync: Settings pane + pairing sheet, localized, snapshot-tested |
| [ADR-069-docs-e2e.md](ADR-069-docs-e2e.md) | Phone Sync: README + website, cross-repo end-to-end, acceptance sweep |
| [ADR-070-podcast-artwork.md](ADR-070-podcast-artwork.md) | Phone Sync: podcast artwork serving |
| [ADR-071-collection-browsing-grids.md](ADR-071-collection-browsing-grids.md) | Collection grids: contract, shared types, mosaic engine, preference keys (read first) |
| [ADR-072-artists-grid.md](ADR-072-artists-grid.md) | Collection grids: shared card infrastructure + Artists grid mode |
| [ADR-073-genres-composers-grid.md](ADR-073-genres-composers-grid.md) | Collection grids: genre/composer card queries + grid modes, view-file split |
| [ADR-074-view-menu-destination-albums.md](ADR-074-view-menu-destination-albums.md) | Collection grids: View menu, genre/composer album destinations, docs |
| [ADR-075-transcode-detection.md](ADR-075-transcode-detection.md) | Transcode detection (audio provenance) |
| [ADR-076-listening-behaviour.md](ADR-076-listening-behaviour.md) | Listening behaviour analytics |
| [ADR-077-podcast-analytics.md](ADR-077-podcast-analytics.md) | Podcast analytics (Library Summary pane) |
| [ADR-078-internet-radio.md](ADR-078-internet-radio.md) | Internet radio stations |
| [ADR-079-e2e-foundations.md](ADR-079-e2e-foundations.md) | E2E: XCUITest foundations, fixture seeding, first journeys |
| [ADR-080-e2e-identifier-coverage.md](ADR-080-e2e-identifier-coverage.md) | E2E: accessibility-identifier coverage sweep |
| [ADR-081-e2e-menu-crawl.md](ADR-081-e2e-menu-crawl.md) | E2E: menu crawl + enablement matrix |
| [ADR-082-e2e-surface-crawl.md](ADR-082-e2e-surface-crawl.md) | E2E: surface crawl (browse destinations, sheets) |
| [ADR-083-e2e-windows-settings.md](ADR-083-e2e-windows-settings.md) | E2E: auxiliary windows + Settings panes |
| [ADR-084-e2e-visualizers.md](ADR-084-e2e-visualizers.md) | E2E: visualizer smoke coverage |
| [ADR-085-e2e-hermetic-network.md](ADR-085-e2e-hermetic-network.md) | E2E: hermetic network (loopback stubs, radio journeys) |
| [ADR-086-e2e-nightly-pipeline.md](ADR-086-e2e-nightly-pipeline.md) | E2E: nightly pipeline, smoke subset, GPU runner |
| [ADR-087-cue-markers.md](ADR-087-cue-markers.md) | CUE sheets as in-track markers (chapters model, supersedes virtual tracks) |

## Conventions used in every ADR

- **Prerequisites**: what must already exist
- **Goal / Non-goals**: keep scope honest
- **Implementation plan**: ordered, small, committable steps
- **Definitions & contracts**: types/protocols/SQL to produce verbatim
- **Context7 lookups**: current-docs references for each dependency
- **Dependencies**: exact SPM / Homebrew additions
- **Test plan**: specific cases, not vibes
- **Acceptance criteria**: checklist to tick before merging
- **Gotchas**: the things that will bite, named in advance
- **Handoff**: what the next ADR expects
