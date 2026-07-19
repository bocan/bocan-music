# Session 9: UI media surfaces

> Read [README.md](README.md) first. Scope + starting points only. Last of the
> four `UI` sessions.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Sources/UI/Visualizers` (incl. `Metal`, `ViewModels`) | 33 | ~5.5k | Visualizer modes, Metal renderers, palettes. |
| `Sources/UI/{DSP,Lyrics,MiniPlayer,Transport}` | 24 | ~4.0k | EQ/DSP UI, lyrics, mini player, transport strip. |
| `Sources/UI/{Fingerprint,Console,Scrobble,WindowModes,MenuBarExtra,DockTile}` | 17 | ~3.4k | Identify-track, log console, recent scrobbles, window/menu-bar surfaces. |

Prereq: Sessions 1 to 8. Gate: `make test-ui`, `make test-coverage`.

## Start here (seeded candidates)

- **Visualizer modes (high-value).** Spectrum bars, oscilloscope, cascade, halo,
  starfield, nebula, and their Metal variants form a large parallel family.
  Normalized-diff the `Metal/` renderers and the CPU `Canvas` visualizers:
  uniform-buffer setup, palette application, and reduce-motion/transparency
  handling are prime shared-plumbing candidates. Keep each mode's *render math*
  distinct (twins by necessity); share the setup/teardown and palette plumbing.
- **Palette handling.** Grep for palette -> colour conversions repeated across
  modes; a single palette resolver is likely.
- **Reduce-motion / reduce-transparency branches.** These accessibility gates
  recur across visualizers and animated surfaces -- check for a shared modifier
  vs copied conditionals.
- **Transport controls.** Play/pause/next/prev/shuffle/repeat button clusters in
  the main strip vs mini player vs menu-bar extra -- likely near-duplicate button
  rows. Share the button row, keep the layout host distinct.
- **Snapshot-test scaffolding.** The visualizer snapshot tests repeat static-
  canvas harnesses; consolidate shared test helpers (like the Session-earlier
  `TestImage`).

## Exit criteria

- All media surfaces triaged; ledger rows for all clusters, especially the
  visualizer family (share-plumbing-not-math decision recorded).
- `make test-ui`, `make test-coverage`, `make lint`, `make build` green.
- `UI` module fully audited across Sessions 6 to 9.
