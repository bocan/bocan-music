# Phase 5.5 — Add Media to Library

> Prerequisites: Phase 5 (Queue & Gapless) complete.
>
> This is an interstitial phase: the Library scanning engine was built in Phase 3,
> but its UI surface was deferred. Without a way to add music, the app is an empty
> shell. Phase 5.5 fills that gap before any further features are built.

## Goal

Give users every standard macOS way to get music into their Bòcan library:

| Entry point | How | Shortcut |
|---|---|---|
| **Add Folder** | `NSOpenPanel` (directories only, multi-select) | `⌘⇧O` |
| **Add Files** | `NSOpenPanel` (audio files only, multi-select) | `⌘O` |
| **Drag & Drop** | Drop folders or audio files anywhere on the main window | — |
| **Empty-state CTA** | "Add Music Folder" button when Songs list is empty | — |
| **Sidebar "+"** | `+` button at the bottom of the Library Folders sidebar section | — |

While a scan is running, a non-blocking **scan banner** slides in at the top of the
content area showing live progress (files walked, tracks inserted/updated) and a
Cancel button.  It auto-dismisses 3 seconds after the scan finishes.

---

## Outcome shape

### New files

```
Modules/UI/Sources/UI/Import/
└── ScanBanner.swift           # Progress overlay shown during scanning

Modules/UI/Sources/UI/Inspector/
└── TrackInspectorPanel.swift  # Read-only ⌘I info panel; Phase 8 replaces it with the full editor
```

### Modified files

| File | Change |
|---|---|
| `Modules/UI/Package.swift` | Add `Library` as a dependency |
| `project.yml` | Add `Library` package + app target dependency |
| `App/BocanApp.swift` | Create `LibraryScanner`, inject into `LibraryViewModel` |
| `Modules/UI/Sources/UI/ViewModels/LibraryViewModel.swift` | Scanner wiring, scan state, picker & drop methods |
| `Modules/UI/Sources/UI/AppRoot/RootView.swift` | `File` menu commands + window-level drag-and-drop |
| `Modules/UI/Sources/UI/Common/KeyBindings.swift` | `addFolder` (`⌘⇧O`) + `addFiles` (`⌘O`) |
| `Modules/UI/Sources/UI/AppRoot/Sidebar.swift` | Library Folders section with roots list + `+` button |
| `Modules/UI/Sources/UI/Browse/TracksView.swift` | Empty-state CTA wired to `addFolderByPicker()` |

---

## LibraryViewModel scan state

New published properties:

```swift
@Published public var isScanning = false
@Published public var scanWalked = 0
@Published public var scanInserted = 0
@Published public var scanUpdated = 0
@Published public var scanCurrentPath = ""
@Published public var scanSummary: ScanProgress.Summary?
@Published public var libraryRoots: [LibraryRoot] = []
```

New public methods:

| Method | Trigger |
|---|---|
| `addFolderByPicker() async` | File menu / sidebar "+" / empty-state button |
| `addFilesByPicker() async` | File menu |
| `addDroppedURLs(_ urls: [URL]) async` | Drag-and-drop |
| `removeRoot(id: Int64) async` | Sidebar right-click context menu |
| `refreshRoots() async` | Called at startup and after each add |
| `dismissScanSummary()` | Manual dismiss of the finished banner |
| `removeTrack(id: Int64) async` | Track context menu "Remove from Library" |
| `rescanTrack(id: Int64) async` | Track context menu "Re-scan File" |
| `deleteTrackFromDisk(id: Int64) async throws` | Track context menu "Delete from Disk" |
| `setAlbumForceGapless(albumID: Int64, forced: Bool) async` | Album context menu "Force Gapless Playback" |

---

## ScanBanner behaviour

- Shown as `.safeAreaInset(edge: .top)` on the main content pane.
- **Scanning state**: indeterminate `ProgressView` + walking count + current path (truncated to last path component) + Cancel button.
- **Finished state**: checkmark, summary line ("4,231 files · 120 new tracks"), auto-hides after 3 s.
- **Error state**: "⚠ N errors during scan" — tap to see list (future phase).
- Animated slide-in/out via `.transition(.move(edge: .top).combined(with: .opacity))`.

---

## Drag-and-drop contract

- Accepts `UTType.fileURL` and `UTType.folder` drops on the `BocanRootView`.
- Directories are passed as roots to `LibraryScanner.addRoot(_:)`.
- Audio files are added individually using `LibraryScanner.addRoot(_:)` with
  their **parent directory** (avoids per-file root explosion for bulk file drops).
- Deduplication of parent dirs before calling `addRoot` prevents duplicate roots.
- Highlights the window with a drop-target border while dragging over.

---

## Library Folders section (Sidebar)

A collapsible "Folders" section at the bottom of the sidebar above Playlists:

```
▸ Folders
  📁 ~/Music/iTunes
  📁 /Volumes/BigDisk/FLAC
  [+]
```

- Each row shows the last path component as label, full path as tooltip.
- Right-click → "Remove from Library" — calls `removeRoot(id:)`, does **not** delete
  files from disk.
- The `+` button triggers `addFolderByPicker()`.

### Per-track context-menu additions (TracksView / AlbumsView)

Add two new items to the existing `ContextMenus.swift` track menu:

| Item | Behaviour |
|---|---|
| **Remove from Library** | Sets `tracks.disabled = 1` (soft delete); does not touch the file on disk. Confirmation alert with "Don't ask again" suppression stored in `settings`. Removes the row from every visible list immediately via `@Published` reload. |
| **Re-scan File** | Calls `ScanCoordinator.scanSingleFile(url:)` — resolves the file URL via the per-file bookmark or the root bookmark fallback, re-reads tags, refreshes the `fileBookmark`, updates the DB row. Shows an inline toast on success or a sheet error on failure. |

`ScanCoordinator.scanSingleFile(url:)` is a new thin method that reuses the existing `processFile` internals; it should complete in < 200 ms for normal files.

### Track Inspector (`⌘I`)

A read-only info panel showing all available metadata and file properties. Invoked via `⌘I`, the "Get Info" context-menu item, or the toolbar button on a selected track. Implemented as a non-modal `Window` with `.windowStyle(.inspector)` so it floats alongside the main window.

| Tab | Fields |
|---|---|
| **Details** | Title, Artist, Album, Album Artist, Year, Genre, Composer, Track №, Disc №, BPM, Rating (read-only stars), Loved |
| **File** | File path (with "Show in Finder" link), Format, Sample rate, Bit depth, Bitrate, File size, Duration |
| **History** | Date added, Date modified, Play count, Skip count, Last played |

Phase 8 converts this into a writable editor using the same `⌘I` shortcut.

### Delete from Disk

"Delete from Disk" in `ContextMenus.swift`, below "Remove from Library":

- Uses `FileManager.default.trashItem(at:resultingItemURL:)` to move to Trash. Falls back to `removeItem(at:)` only if trashing fails, with an additional explicit confirmation.
- **Two-step confirmation**: alert — “Move «Title» to Trash and remove from Bòcan?” (Move to Trash / Cancel).
- On success: calls `removeTrack(id:)` (soft-delete) then removes the file. DB row is not hard-deleted so play history is preserved; the file path is cleared.
- On failure: shows an error sheet; does **not** touch the DB row.
- Requires the security-scoped URL resolved from the per-file or root bookmark.

### Force Gapless per Album

Some albums are gapless by production intent but lack iTunSMPB / Vorbis padding tags — common with rips from certain tools. Bòcan allows forcing gapless at the album level regardless of tag presence.

**Schema** — add a column to `albums` via a new migration (numbered to slot before Phase 7’s smart-playlist migration):

```sql
ALTER TABLE albums ADD COLUMN force_gapless INTEGER NOT NULL DEFAULT 0;
```

**UI** — right-click an album in AlbumsGridView or AlbumDetailView → "Force Gapless Playback" (checked/unchecked toggle).

**Playback** — `QueuePlayer.loadAndPlay` checks `album.force_gapless` for the current and next queued item. When both share the same `album_id` and `force_gapless = 1`, `GaplessScheduler` is invoked even when it would otherwise skip gapless due to missing padding tags. Different sample rates still require `FormatBridge`; the flag only overrides the “no padding tags → skip gapless” short-circuit, not the hardware sample-rate constraint.

---

## Acceptance criteria

- [ ] `File > Add Folder to Library…` (`⌘⇧O`) opens a folder picker and starts a scan.
- [ ] `File > Add Files to Library…` (`⌘O`) opens a file picker and starts a scan.
- [ ] Dragging a folder or audio file(s) onto the main window adds and scans them.
- [ ] The scan banner appears while scanning and auto-hides 3 s after finishing.
- [ ] Cancelling a scan mid-way stops progress and hides the banner.
- [ ] The Songs empty state shows "Add Music Folder" with a working CTA button.
- [ ] The Sidebar shows added folders; right-click allows removal.
- [ ] Right-click a track → "Remove from Library" soft-deletes it; the row disappears from all views immediately.
- [ ] Right-click a track → "Re-scan File" refreshes its tags and bookmark without a full scan; success shown via toast.
- [ ] `⌘I` opens the Track Inspector showing correct metadata, file info, and play history.
- [ ] Right-click a track → "Delete from Disk" moves the file to Trash and removes it from every view.
- [ ] Right-click an album → "Force Gapless Playback" toggle persists and is honoured during playback.
- [ ] `make lint` is clean; `make test-ui` is green.

---

## Out of scope for this phase

- Removing tracks that were deleted from disk (Phase 4 incremental sync).
- Editing tags (Phase 8).
- Watching folders for live changes (FSWatcher wired in Phase 4).
- Showing per-file errors in detail (noted in banner, expanded in Phase 8).
- Editing tags in the inspector (Phase 8 full editor).
