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

---

## Acceptance criteria

- [ ] `File > Add Folder to Library…` (`⌘⇧O`) opens a folder picker and starts a scan.
- [ ] `File > Add Files to Library…` (`⌘O`) opens a file picker and starts a scan.
- [ ] Dragging a folder or audio file(s) onto the main window adds and scans them.
- [ ] The scan banner appears while scanning and auto-hides 3 s after finishing.
- [ ] Cancelling a scan mid-way stops progress and hides the banner.
- [ ] The Songs empty state shows "Add Music Folder" with a working CTA button.
- [ ] The Sidebar shows added folders; right-click allows removal.
- [ ] `make lint` is clean; `make test-ui` is green.

---

## Out of scope for this phase

- Removing tracks that were deleted from disk (Phase 4 incremental sync).
- Editing tags (Phase 8).
- Watching folders for live changes (FSWatcher wired in Phase 4).
- Showing per-file errors in detail (noted in banner, expanded in Phase 8).
