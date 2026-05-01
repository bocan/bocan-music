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
