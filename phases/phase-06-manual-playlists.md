# Phase 6 — Manual Playlists

> Prerequisites: Phases 0–5 complete. Queue works. UI context-menu stubs exist.
>
> Read `phases/_standards.md` first.

## Goal

Create, edit, reorder, rename, delete playlists. Multi-select-to-create workflow feels like a single motion. Drag-and-drop between views and the sidebar. Folders for organisation. Per-playlist cover art and accent colour.

## Non-goals

- Smart (rule-based) playlists — Phase 7.
- Import/export (M3U, etc.) — Phase 14.
- Collaborative/shared playlists — out of scope.
- Playlist sync via iCloud — not in v1 (DB backup in Phase 2 is the nearest thing).

## Outcome shape

```
Modules/Library/Sources/Library/Playlists/
├── PlaylistService.swift              # Actor; all mutations go through here
├── PlaylistReorder.swift              # Positional helpers (insert, move, gap-pack)
└── PlaylistFolderTree.swift           # parent_id navigation

Modules/UI/Sources/UI/Playlists/
├── PlaylistSidebarSection.swift
├── PlaylistRow.swift
├── PlaylistFolderRow.swift
├── PlaylistDetailView.swift           # Table + header
├── PlaylistHeader.swift               # cover art + name + counts + play/shuffle
├── NewPlaylistSheet.swift
├── AddToPlaylistMenu.swift            # Builds the nested menu
└── ViewModels/
    ├── PlaylistSidebarViewModel.swift
    └── PlaylistDetailViewModel.swift

Tests live in the owning module.
```

## Implementation plan

1. **Confirm schema** from Phase 2 has everything we need:
   - `playlists(id, name, is_smart, smart_criteria, sort_order, parent_id, cover_art_path, accent_color, created_at, updated_at)`
   - `playlist_tracks(playlist_id, track_id, position)` — composite PK `(playlist_id, position)`.
   - If `accent_color` wasn't added in M001, add it in a new migration `M002_PlaylistAccent`.

2. **`PlaylistService`** (actor):
   ```swift
   public actor PlaylistService {
       public init(database: Database, logger: AppLogger = .make(.library))

       // CRUD
       public func create(name: String, parentID: Int64? = nil) async throws -> Playlist
       public func createFolder(name: String, parentID: Int64? = nil) async throws -> Playlist
       public func rename(_ id: Int64, to name: String) async throws
       public func delete(_ id: Int64) async throws
       public func setCoverArt(_ id: Int64, imageData: Data?) async throws
       public func setAccentColor(_ id: Int64, hex: String?) async throws
       public func move(_ id: Int64, toParent parentID: Int64?) async throws

       // Membership
       public func addTracks(_ trackIDs: [Int64], to playlistID: Int64, at index: Int? = nil) async throws
       public func removeTracks(at positions: IndexSet, from playlistID: Int64) async throws
       public func moveTracks(in playlistID: Int64, from source: IndexSet, to destination: Int) async throws
       public func clear(_ playlistID: Int64) async throws

       // Queries
       public func list() async throws -> [PlaylistNode]          // folder tree
       public func tracks(in playlistID: Int64) async throws -> [Track]
       public func observe(_ playlistID: Int64) -> AsyncThrowingStream<[Track], Error>
   }
   ```

3. **Position management** — `playlist_tracks.position` is a sparse integer. New inserts at end pick `max(position) + 1024`. Middle-inserts pick the midpoint between neighbours (`(prev + next) / 2`). If the gap collapses to 1, the service silently re-packs positions at 1024-steps. This matches Trello/Notion-style reorder without full re-numbering on every move.

4. **Folders** — a playlist row with `is_folder = 1` (add column via migration if not present — or repurpose `is_smart` semantics carefully; prefer a new `kind TEXT CHECK(kind IN ('manual','smart','folder'))` column and drop `is_smart` over a migration). Folders have no tracks; they contain child playlists via `parent_id`. The service prevents cycles: moving folder A into its own descendant throws.

5. **Sidebar section** — `PlaylistSidebarSection` below "Recents":
   - Shows folder tree with disclosure triangles.
   - Row: icon (folder / music.note.list / sparkles for smart) + name + track count.
   - Drag a track (or selection) onto a playlist row → enqueue into that playlist.
   - Drag a playlist row onto a folder → moves under that folder.
   - Rename in place on `Return` when focused.
   - Context menu: New Playlist, New Folder, Rename, Duplicate, Delete, Set Cover Art, Set Accent Colour, Sort Contents (by title/artist/added).

6. **New Playlist UX**:
   - Three entry points:
     1. Sidebar "+" button: opens `NewPlaylistSheet` (name field, folder picker, optional "From Selection" toggle if there's a current multi-select).
     2. Context menu on a selection: "New Playlist from Selection" — creates immediately, name pre-filled to a date-based suggestion (`"New Playlist 2026-04-18"`), Enter confirms.
     3. `⌘⇧N` from anywhere.
   - After creation, sidebar focus moves to the new row in rename mode so the user can type.

7. **Add to Playlist menu** — a nested `Menu` built from `PlaylistService.list()`:
   - "Add to Playlist ▸" → folder items cascade to submenus; leaf items insert.
   - At the top: "New Playlist from Selection…" and a divider.
   - Keyboard-friendly: first-letter typing jumps items.

8. **Playlist detail view**:
   - Header: big cover (user-set or computed from first 4 unique album covers in a 2×2 mosaic), title, track count, total duration, play + shuffle buttons, context menu.
   - Table: same `TracksView` component but with an explicit "position" column (or a drag handle) and drag-to-reorder.
   - Dropping tracks onto the table inserts them at the drop index.
   - Deleting rows (`⌫` key) removes from the playlist only, never from the library — confirm exactly once and remember the choice via a "Don't ask again" checkbox.

9. **Duplicate** — creates a new playlist with name `"<original> copy"` and the same tracks in the same order. Cover/accent copied too.

10. **Delete** — with confirm. Cascade deletes `playlist_tracks` rows. Tracks untouched. Folders: "Delete folder and its N playlists?" or "Delete folder only (keep contents)?" — offer both.

11. **Persistence of UI state** — which folders are expanded, which playlist was last selected. Encoded in the `ui.state.v1` JSON already established in Phase 4.

12. **Playback integration** — `PlaylistDetailView` has a big Play button that calls `QueuePlayer.replace(with: tracks, startAt: 0)`; Shuffle button sets shuffle on with a fresh seed then calls the same. Double-click a row plays from that row.

13. **Cover art generation** — if no user-set cover, compute a 2×2 mosaic of the first 4 unique album covers (or a single large cover if there's only one album). Cache the result on disk keyed by the playlist's updated_at; invalidate on change.

14. **Accent colour** — stored as a CSS-style hex string. Applied to:
    - Playlist row dot in sidebar.
    - Header tint.
    - Selection highlight in detail table (subtle).
    Defaults to system accent if unset.

## Definitions & contracts

### `PlaylistNode`

```swift
public struct PlaylistNode: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let kind: Kind                  // .manual, .smart, .folder
    public let parentID: Int64?
    public let coverArtPath: String?
    public let accentHex: String?
    public let trackCount: Int
    public let totalDuration: TimeInterval
    public let children: [PlaylistNode]    // populated only for folders

    public enum Kind: String, Sendable { case manual, smart, folder }
}
```

### `AddToPlaylistMenu` action signatures

```swift
struct AddToPlaylistAction: Sendable {
    let selection: Set<Track.ID>
    let service: PlaylistService
    func perform(for node: PlaylistNode) async throws
}
```

## Context7 lookups

- `use context7 SwiftUI List DisclosureGroup hierarchical`
- `use context7 SwiftUI Transferable drop reorder`
- `use context7 SwiftUI sheet Form @FocusState`
- `use context7 GRDB composite primary key reorder`

## Dependencies

None new.

## Test plan

### Service

- CRUD round-trips: create, rename, delete — observed via DB inspection.
- `addTracks` at end: positions are strictly increasing, `position - prev >= 1`.
- `addTracks` at middle: new positions sit between neighbours.
- `moveTracks` with multiple indices: final order matches `source + offset` semantics (same as SwiftUI `move(fromOffsets:toOffset:)` — verify by parity).
- Repack is triggered when any adjacent gap falls to 1; after repack, positions form an arithmetic progression with step 1024 and relative order is preserved.
- Duplicate adds of the same track are allowed (a playlist can legitimately contain the same track twice).
- Deleting a playlist does not delete tracks from the library.
- Moving a folder into itself throws `PlaylistError.cycleDetected`.
- Deleting a folder with children: both "delete all" and "keep children (reparent to grandparent)" paths work.

### UI

- Snapshot: sidebar with nested folders, empty playlist, populated playlist, dark + light.
- Snapshot: playlist header with mosaic cover of 4 albums.
- Multi-select 20 tracks → context menu → "New Playlist from Selection" → enter name → the playlist exists with 20 tracks in visible order.
- Drag a single track over a folder row → row highlights; drop → expands folder and inserts into the highlighted child... actually, dropping onto a folder appends to the folder itself only if it's a playlist; folder drops do nothing audible (spec decision: dropping onto a folder expands it, require user to drop on a child playlist; document in-code).
- Drag-reorder a row within a playlist — UI updates immediately; DB confirms eventually; no flicker.
- Rename in place commits on `Return`, cancels on `Esc`.
- Deleting the currently-playing playlist does not interrupt playback (queue is decoupled from the playlist source).

### Property-based

- Arbitrary sequences of add/remove/move → final track order equals a reference in-memory list applied with the same ops. (Model-check the DB against an in-Swift oracle.)

## Acceptance criteria

- [ ] Select 20 tracks, create playlist, type name, done — in under 3 seconds of keystrokes.
- [ ] Drag 50 tracks onto a playlist in the sidebar → all appear in order.
- [ ] Reorder by drag inside a playlist feels native.
- [ ] Folders with nested playlists work; no cycles possible.
- [ ] Empty playlist looks intentional (illustrated empty state with "Drag tracks here").
- [ ] Delete confirms once, "Don't ask again" is respected.
- [ ] Cover mosaic renders and updates when membership changes.
- [ ] Play / Shuffle buttons replace the queue and start playing correctly.
- [ ] 80%+ coverage on new code.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **SwiftUI drag-reorder with `List`** uses `move(fromOffsets:toOffset:)`. Our underlying ordering uses sparse integer positions; the adapter layer must translate. Write a small `PositionArranger` helper with tests — this is the bug magnet.
- **Composite PK `(playlist_id, position)`** makes middle-insert require either temporarily violating the unique constraint or always inserting at a fresh midpoint. Use midpoint; repack when gaps collapse.
- **`playlist_tracks` ON DELETE CASCADE** — if missing from M001, add a migration to recreate the FK (SQLite quirk: altering a FK means renaming the table). Much easier to get right the first time in Phase 2.
- **Duplicate tracks in one playlist**: `UNIQUE(playlist_id, track_id)` would forbid this. Don't add that constraint; users sometimes want it.
- **Sidebar drag acceptance**: only accept drops of known `Transferable` types. Reject random strings and files (those go to the import flow in Phase 14).
- **`⌫` in a table row that's in rename mode**: intercept — don't delete the row when the user is editing text. `@FocusState` plus explicit key handler.
- **Rename collisions**: two playlists with the same name under the same parent — allowed, but warn via inline hint. Fully-qualified name (folder/playlist) is the identity; the raw name isn't unique.
- **Cover mosaic perf**: compute off-main-thread, cache aggressively. Regenerating on every membership change is wasteful — debounce 500ms.
- **Folder "Play"**: a folder's context menu doesn't get a Play button; too surprising. Drilling in to a child does.
- **Snapshot flakiness on mosaic**: cover hashes must be deterministic for the snapshot fixture to match. Use a stable seed.

## Handoff

Phase 7 (Smart Playlists) expects:

- The sidebar section treats `.manual` and `.smart` uniformly; smart items get a `sparkles` icon.
- `PlaylistDetailView` is generic over a tracks source (a `[Track]` provider) — a smart playlist injects a live-query provider instead of the static `playlist_tracks` one.
- `PlaylistService.create` has a sibling `createSmart(name:criteria:parentID:)` added in Phase 7 with the same folder/tree rules.
- `Add to Playlist ▸` menu hides smart playlists (you can't add to a smart one) and folders that contain only smart children become non-target.
