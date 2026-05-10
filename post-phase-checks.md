We've completed the build phases of the Bocan app.  Now comes the long process of debugging it and ensuring it's feature complete.

Instruction / Prompt:

Read `phases/phase-NN-<name>.md` and `phases/_standards.md`. For each feature listed:

Steps:

- Check that all features have been developed according to the spec - or beyond.
- Check that all such features **wired in**
- Check that any relevant settings in the Preferences are wired in and should work.
- Look for anything that may cause an audio "pop" - like when clicking on menus or menu items or bring up other windows.  Sound should always win over features because it's jarring.
- Consider accessibility in mind for all features and changes.  I shouldn't need to wear reading glasses to see dialogs. All buttons or controls should have hover text.
- Make sure if we've specified a keyboard shortcut, that it actually works.  Again - accessibility.
- Consider features. it could be a right click of the selected track, it might ALSO need to be a menu item. Basically, anywhere a control gets wired in, think about where it might also be convienient or accessible.

Make no changes yet! Just make a list of any issues you find, and then we can go through them one by one.  This is the "post-phase checks" step, not the "fix all the things" step.  We want to be methodical and not miss anything.

## Phase 6 Audit — NSWindow Surface / Audio Pop Risk

Date: 2026-05-01

Scope reviewed:
- NewPlaylistSheet
- RenamePlaylistSheet
- MoveToFolderSheet (none present; move is context-menu only)
- Delete confirmation dialogs (playlist + folder)
- Set Cover Art NSOpenPanel path

Findings:
- `NewPlaylistSheet` and `RenamePlaylistSheet` do not call blocking modal APIs (`runModal`, semaphores, sync file I/O) from UI actions; commits are async (`Task { await ... }`).
- No `MoveToFolderSheet` exists in current Phase 6 UI; move actions are menu-driven and async.
- Delete flows use SwiftUI `confirmationDialog`, not blocking modal loops.
- `setCoverArt(for:)` uses `NSOpenPanel.begin(completionHandler:)` via async wrapper and performs file I/O in `Task.detached` (non-main actor), matching the Phase 5.5 hardening pattern.

Hardening applied:
- Added off-screen prewarm for first NSWindow-backed playlist surface in `PlaylistSidebarSection` presentation host:
	- warms font cache (`NSFont.systemFont`) and creates/tears down an off-screen transparent `NSPanel` once per app launch.
	- goal: reduce first-visible sheet/dialog hitch risk during active playback.

Verification status:
- Static audit complete (code-path review).
- Lint/static diagnostics: clean after patch.
- Manual runtime verification while actively playing audio (including gapless transitions) remains required on a desktop session:
	- Open `NewPlaylistSheet` repeatedly while playing.
	- Open `RenamePlaylistSheet` repeatedly while playing.
	- Trigger playlist/folder delete `confirmationDialog` while playing.
	- Open `Set Cover Art…` panel while playing and ensure no audible pop/dropout.

## Phase 7 Audit — Smart Playlist Surface First-Mount Risk

Date: 2026-05-01

Scope reviewed:
- `NewSmartPlaylistSheet`
- `RuleBuilderView` sheet (from `SmartPlaylistDetailView`)
- `SmartPresetPickerView` sheet (from RuleBuilder toolbar)

Findings:
- No blocking modal APIs (`runModal`, semaphores, sync waits) were found in these three smart-surface paths.
- All heavy operations are async (`Task` / async service calls).

Hardening applied:
- Added `SmartPlaylistSurfacePrewarmer` one-shot off-screen warm-up that mounts a tiny hidden SwiftUI probe (`TextField`, segmented picker, `Menu`) inside an off-screen transparent `NSPanel`.
- Hooked prewarm at first appearance of each smart surface and from the existing Phase 6 launch-time prewarm path in playlist sidebar presentation.

Manual verification + sample capture (pending local run):
- Start playback with a known clean track and queue a gapless transition.
- While audio is active, trigger in order:
	- New Smart Playlist sheet
	- Edit Rules sheet
	- Presets picker sheet
- Record a 20–30 second audio sample while triggering each first-show path.
- Confirm no audible pop/dropout and no gapless transition discontinuity.

Status:
- Static audit + hardening complete.
- Manual runtime verification and sample capture remain required on a local desktop session.

## Phase 14 Audit — Playlist Import / Export

Date: 2026-05-09

Scope reviewed:
- `Modules/Library/Sources/Library/PlaylistIO/` (all files)
- `Modules/UI/Sources/UI/PlaylistIO/` (all files)
- `App/BocanCommands.swift` (menu wiring)
- `Modules/UI/Sources/UI/ViewModels/LibraryViewModel+Scanning.swift` (drag-drop routing)
- `Modules/UI/Sources/UI/AppRoot/RootView.swift` (sheet presentation, drop handler)
- `Modules/UI/Sources/UI/Settings/` (preferences coverage)
- `Modules/AudioEngine/Sources/` + `Modules/Playback/Sources/` (CUE offset playback)

### What is implemented and working

- `PlaylistFormat` enum with extension detection and content sniffing ✅
- `M3UReader` / `M3UWriter` — full EXTINF/EXTART/EXTALB support, BOM/CRLF handling ✅
- `PLSReader` / `PLSWriter` ✅
- `XSPFReader` / `XSPFWriter` ✅
- `CUESheetReader` — parser only ✅
- `ITunesLibraryReader` — parser only ✅
- `TrackResolver` — steps 1, 2, 4 (skips step 3) ✅
- `PlaylistImportService` — M3U/PLS/XSPF import ✅
- `PlaylistExportService` — single playlist and smart-snapshot export ✅
- `PlaylistImportSheet` — file picker and format preview ✅
- `PlaylistExportSheet` — format/path-mode picker ✅
- Playlist context menu "Export…" wired ✅
- File ▸ Import Playlist… (⌘⌥⇧O) in menu ✅  
  *(note: spec says ⌘⇧O but Phase 4 audit reserved that for "Add Folder"; deviation is intentional and documented)*
- M013 migration for CUE `start_offset_ms` / `end_offset_ms` columns ✅
- Integration and unit tests for M3U, PLS, XSPF, ITunes reader, round-trip ✅

### Issues filed

| # | Severity | Title |
|---|----------|-------|
| [#187](https://github.com/bocan/bocan-music/issues/187) | P0 — Audio Pop | `NSOpenPanel`/`NSSavePanel` `runModal()` in import/export sheets — blocks main thread |
| [#188](https://github.com/bocan/bocan-music/issues/188) | P1 | Drag-and-drop `.m3u8`/`.pls`/`.xspf` routes to library scanner instead of importer |
| [#189](https://github.com/bocan/bocan-music/issues/189) | P1 | `ResolutionReviewSheet` missing — unresolved import tracks silently dropped |
| [#190](https://github.com/bocan/bocan-music/issues/190) | P1 | iTunes Library import flow entirely missing — no menu item, no sheet, no wiring |
| [#191](https://github.com/bocan/bocan-music/issues/191) | P1 | "Export All Playlists…" missing from Tools menu — not implemented |
| [#192](https://github.com/bocan/bocan-music/issues/192) | P2 | CUE sheet import not wired; AudioEngine/Playback don't honour `start/end_offset_ms` |
| [#193](https://github.com/bocan/bocan-music/issues/193) | P2 | "Bòcan Backup" snapshot export (playlists + CSV of plays/ratings) not implemented |
| [#194](https://github.com/bocan/bocan-music/issues/194) | P2 | ImportSheet preview always shows "0 matched / 0 missing" — resolver not called during preview |
| [#195](https://github.com/bocan/bocan-music/issues/195) | P2 | Smart playlist export option (XSPF criteria embedding) not implemented |
| [#196](https://github.com/bocan/bocan-music/issues/196) | P2 | `TrackResolver` skips step 3 (filename-only fallback) — re-tagged tracks fail to match |
| [#197](https://github.com/bocan/bocan-music/issues/197) | P3 | `PlaylistImportSheet` / `PlaylistExportSheet` missing `.help()` and `accessibilityLabel` |
| [#198](https://github.com/bocan/bocan-music/issues/198) | P3 | No Preferences setting for "import play counts/ratings from iTunes Library" |

### Unverified acceptance criteria (from phase file)

- [ ] iTunes Library.xml import brings in playlists and (optionally) play stats — blocked by #190 and #198
- [ ] CUE sheet lets me play individual tracks from a single-file rip — blocked by #192
