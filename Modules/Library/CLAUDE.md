# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Library` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

Turning folders of files on disk into the persisted library, keeping them in sync, and the playlist/smart-playlist logic. It is the largest non-UI module.

- **Scanning:** `FileWalker` enumerates folders, `LibraryScanner` reads metadata and upserts rows, `ScanCoordinator` orchestrates a run and emits `ScanProgress`, `ChangeDetector` decides what changed, `ConflictResolver` reconciles duplicates.
- **Watching:** `FSWatcher.swift` wraps FSEvents so the library updates when files appear/disappear.
- **Smart playlists:** `SmartPlaylists/` with `Compiler/` (notably `SQLBuilder`) translates a criteria tree into SQL. `PlaylistIO/Formats/` reads/writes m3u/pls/etc. `Lyrics/`, `Fingerprint/`, and `CoverArt/` round out per-track enrichment.
- `SecurityScope.swift` is the sandbox file-access helper.

## Things easy to get wrong

- **All sandboxed file access goes through `SecurityScope`.** Use `SecurityScope.withAccess(url) { … }` (sync or async); never scatter raw `url.startAccessingSecurityScopedResource()` / `stop…` calls. Entitlements are added per feature, not pre-emptively.
- **`SmartPlaylists/Compiler/SQLBuilder` builds raw SQL**, so every user-supplied operand must be escaped. LIKE terms use the `escapeLIKETerm` helper plus an `ESCAPE` clause; day-bucket date math pins a Gregorian `Calendar` to the device timezone rather than using `Calendar.current` (which can shift the year under non-Gregorian locales).
- **`FSWatcher` holds FSEvents handles** that the nonisolated `deinit` must release, hence the `nonisolated(unsafe)` stored stream/roots. Keep that pattern when touching it.
- `DateFormatter`s with a fixed format string set `locale = en_US_POSIX`, or non-Gregorian locales produce wrong years in generated names.

## Testing

Run `make test-library` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/Library`, or `make test-coverage`), run `make test-library` last so the full module suite is the final gate before the commit.
