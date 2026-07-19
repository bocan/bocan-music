# Session 8: UI creation + config

> Read [README.md](README.md) first. Scope + starting points only.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Sources/UI/Playlists` (incl. `Smart`, `ViewModels`) | 27 | ~4.9k | Manual + smart playlists, rows, folders, mosaic header. |
| `Sources/UI/Settings` | 20 | ~3.0k | System-Settings-style panes. |
| `Sources/UI/MetadataEditor` (incl. `ViewModels`) | 14 | ~2.7k | Tag editor sheet + tabs. |
| `Sources/UI/{PlaylistIO,Import,Tools}` | 7 | ~1.1k | Import/export, tools sheets. |

Prereq: Sessions 1 to 7. Gate: `make test-ui`, `make test-coverage`,
`make pseudolocale` if the catalog changes.

## Start here (seeded candidates)

- **Settings rows/sections (high-value).** ~11 Settings files use `Form` /
  `GroupBox` with repeated labelled-row / toggle-with-help / picker-row shapes.
  A small set of settings-row components (a labelled control, a help-annotated
  toggle) likely removes a lot of copy-paste. Classic safe dedup: config-free
  leaf views. Measure and extract the ones with 3+ copies.
- **Manual vs smart playlist detail.** `PlaylistDetailView` vs
  `SmartPlaylistDetailView` -- normalized-diff for shared header/subtitle/track
  rendering. The Phase 23 mosaic generator is already shared; confirm the
  headers do not re-implement it.
- **Playlist rows.** `PlaylistRow`, `PlaylistFolderRow`, smart-playlist rows --
  parallel row types; share the config-free parts.
- **Tag editor tabs.** `TagEditorSheet` + its tab files repeat field-row layout
  (label + editor + revert). A shared tag-field-row is a strong candidate.
- **Sheet chrome.** New/rename/accent sheets repeat title + form + cancel/confirm
  scaffolding -- check for a shared sheet wrapper.

## Exit criteria

- All four areas triaged; ledger rows for all clusters.
- Any new user-facing copy in shared components routes through `L10n`;
  `make pseudolocale` run if the catalog changed.
- `make test-ui`, `make test-coverage`, `make lint`, `make build` green.
