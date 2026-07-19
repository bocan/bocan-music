# Session 2: AudioEngine + Metadata + Acoustics

> Read [README.md](README.md) first. Scope + starting points only.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Modules/AudioEngine/Sources` | 46 | ~5.8k | Engine actor, graph, decoders, DSP chain, stream cache. |
| `Modules/Metadata/Sources` | 8 | ~1.0k | TagLib read/write, cover-art, LRC parsing. |
| `Modules/Acoustics/Sources` | 8 | ~0.8k | Chromaprint + AcoustID + MusicBrainz lookup. |

Prereq: Session 1 (may dedup against Persistence's shared surface). Gates:
`make test-audio-engine`, `make test-metadata`, `make test-acoustics`.

## Start here (seeded candidates)

- **The decoder split.** `AVFoundationDecoder`, `FFmpegDecoder`, `DecoderFactory`,
  `FormatSniffer` -- parallel decoders behind a common protocol. Normalized-diff
  the two decoders; look for buffer/format handling copied between them that
  could move to a shared base or free function. **Caution:** decoders that must
  stay behaviorally distinct are the "twins by necessity" case -- share only
  genuinely identical plumbing, not the decode logic.
- **DSP chain nodes.** The DSP node types likely repeat parameter-clamping and
  tap wiring. Look for a per-node boilerplate a small helper removes.
- **Buffer / conversion helpers.** Grep for repeated `AVAudioPCMBuffer` setup and
  format conversions across the engine.
- **Acoustics HTTP + JSON.** AcoustID and MusicBrainz lookups do request-build +
  decode + error-map. This shape recurs in Scrobble (Session 4) and Subsonic
  (Session 5) -- if you see a reusable HTTP-client pattern here, **defer it to
  Session 10** (cross-module) rather than sharing it upward now.
- **Metadata read/write.** TagLib read vs write paths (note the read-only vs
  read-write open trap in repo memory) -- check for duplicated field-mapping.

## Exit criteria

- AudioEngine, Metadata, Acoustics fully triaged; ledger rows for all clusters.
- Any HTTP/JSON client shape logged as **deferred -> Session 10**.
- `make test-audio-engine` (needs the FFmpeg `PKG_CONFIG_PATH`, see root
  `CLAUDE.md`), `make test-metadata`, `make test-acoustics`, `make lint`,
  `make build` green.
