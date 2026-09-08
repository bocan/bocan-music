# ADR-090: Duplicate Review, done properly

> Depends on: ADR-003 (persistence; `tracks.content_hash` exists "to detect duplicates across different paths"), ADR-004 (scanner, FSEvents watcher), ADR-007 (per-file bookmarks at import), ADR-010 (the original "Find Duplicates by Tag" sketch, which promised a side-by-side reviewer that was never built), ADR-080 (identifier coverage), ADR-083 (window and sheet crawls).
> Binding docs: `_standards.md`; `localization.md`; the accessibility and testing sections of the root `CLAUDE.md`; the sandbox notes in `DEVELOPMENT.md`.
> Requested by the maintainer, 2026-09-05, after the first real use of the tool against 259 iCloud Music Library copies that appeared beside their own rips on 2025-08-25.

## Goal

Make Tools > Find Duplicates a tool that finishes the job. Today it finds groups by a loose tag key, shows too little per copy to choose between them, offers one action ("Remove", which only flags the row), rebuilds the whole list after every click so the user lands back at the top, and has no search. Worse, the one thing it does is undone later: the next scan sees the file still on disk and clears the flag.

After this ADR:

- **Finding** uses the content hash first (byte-identical copies under different names or paths, the iCloud case exactly) and a properly normalised tag key second, so neither kind is missed.
- **Choosing** is possible: each copy shows format, bitrate, sample rate, size, path, date added, and whether the decoder reports damage, and the tool proposes a keeper.
- **Acting** is real: "Keep this one" moves the other copies to the Trash, under the sandbox scope the folder needs, so the duplicates are gone from disk and stay gone. "Remove from library" stays for the odd case where a file must remain.
- **Staying put**: the list updates in place. Acting on a group removes that group and selects the next; nothing reloads, nothing scrolls to the top.
- **Search** filters groups by title, artist, album or path.

One rule carries the design: **the Trash is the undo.** No in-app undo stack; every disk action is a `trashItem`, never `removeItem`, unless trashing fails and the user explicitly confirms a permanent delete, the same escalation the track list already uses.

## Non-goals

- **Acoustic matching.** Same recording, different masters, is a fingerprint problem (AcoustID exists in the app). Out of scope here; see Handoff.
- **Merging play history.** When a duplicate is trashed its play counts, rating and loved flag go with it. Merging into the keeper is a follow-up.
- **Subsonic duplicates.** Local files only.
- **Automatic bulk rules** ("trash every four-letter copy"). The search field gets the user most of the way; a rule engine is a follow-up.
- **Hard-deleting database rows.** Rows stay soft-deleted (`disabled = 1`) as everywhere else; the orphan pruner handles albums and artists.

## Outcome shape

New files:

| File | Purpose |
|---|---|
| `Modules/Library/Sources/Library/Duplicates/DuplicateFinder.swift` | Pure grouping: hash groups, then normalised tag groups over the remainder; keeper ranking. No UI, no database. |
| `Modules/Library/Sources/Library/Duplicates/DuplicateGroup.swift` | The group and copy models with stable identities. |
| `Modules/Library/Sources/Library/Delete/TrackFileDeleter.swift` | Trash or remove a track's file under the right security scope (root scope, per-file bookmark fallback), the way `EditTransaction` acquires scope for tag writes. |
| `Modules/Library/Tests/LibraryTests/DuplicateFinderTests.swift` | Grouping, normalisation and ranking. |
| `Modules/Library/Tests/LibraryTests/TrackFileDeleterTests.swift` | Trash under a temp root with a fake scope. |
| `Modules/UI/Tests/UITests/ViewModelTests/DuplicateReviewViewModelTests.swift` | In-place updates, keeper action, search. |
| `Modules/UI/Tests/UITests/SnapshotTests/SnapshotTests+DuplicateReview.swift` | Light, dark and increased-contrast snapshots of a populated sheet. |
| `UITests/Tools/DuplicateReviewTests.swift` | E2E: open, search, keep-one-trash-rest on fixture copies, position kept. |

Changed files:

| File | Change |
|---|---|
| `Modules/UI/Sources/UI/Tools/DuplicateReviewViewModel.swift` | Delegates grouping to `DuplicateFinder`; stable ids; in-place removal; search; keeper action; per-copy facts. |
| `Modules/UI/Sources/UI/Tools/DuplicateReviewSheet.swift` | Search field, richer rows, keeper radio, group and copy actions, identifiers, help. |
| `Modules/UI/Sources/UI/ViewModels/LibraryViewModel+Delete.swift` | All disk deletion goes through `TrackFileDeleter`, so the existing Delete from Disk paths gain the scope they are missing today. |
| `Modules/UI/Sources/UI/ViewModels/LibraryViewModel+Scanning.swift` | `removeTrack(id:)` prunes orphans like the disk paths do. |
| `Modules/UI/Sources/UI/Accessibility/A11yIdentifiers.swift` | `A11y.DuplicateReview`. |
| `Modules/UI/Sources/UI/Resources/Localizable.xcstrings` | New keys and plurals; `make pseudolocale` after. |
| `Modules/UI/Tests/UITests/ViewModelTests/DuplicateReviewCenteringTests.swift` | Updated for the restructured sheet, or retired if the centring is covered by the snapshot. |
| `UITests/Menus/MenuInvocationTests.swift` | Finds the sheet by identifier instead of `app.sheets.firstMatch`. |
| `CHANGELOG.md`, `README.md`, `website/` feature page, `docs/design-spec/README.md` | Release note, feature docs, ADR index row. |

## What carries over from previous specs

- **Soft delete everywhere.** `disabled = 1` is how rows leave the library; the scanner's change detector and the FSEvents watcher both set it when a file vanishes (`LibraryScanner.handleFSChange`, `ScanCoordinator`). Nothing here hard-deletes rows.
- **The scanner clears `disabled` when a file reappears** (`ScanCoordinator`, the reappearance branch). This is the reason "Remove" alone cannot resolve a duplicate whose file stays on disk: it comes back at the next scan. Trashing the file is the only durable answer.
- **Disk deletion pattern.** `LibraryViewModel+Delete` already has `TrackFileDeleter`-style injection (`SystemTrackFileDeleter`, `DeleteFromDiskOutcome`), trash-then-disable ordering, batch-then-one-reload, orphan pruning, and the NSAlert confirmations in `TracksView+Actions` (`confirmDeleteFromDisk`, `confirmPermanentDelete`). This ADR moves the file operation itself down into `Library` and reuses the rest as is.
- **Security scope for writes.** `EditTransaction.acquireRootScope(for:)` matches a file against the library roots, resolves the root bookmark, and holds `RootScopeHandle` for the whole operation, falling back to the per-file bookmark (`Track.fileBookmark`) when no root covers the file. Trashing writes to the parent directory, so it needs the same treatment.
- **Update in place, do not reload.** `LibraryViewModel+Scanning.refreshTracks(ids:)` and its rationale (issue 343): a full reload flips `isLoading`, tears the list out for a spinner, resets scroll. Same rule here.
- **Content hash.** `tracks.content_hash` is backfilled in the background (`ContentHashService`). It can be null for tracks not yet hashed; the finder must cope.
- **Every control ships an `A11y` id and localized help**, joins a crawl registry, and every user-facing string goes through `L10n` with plurals in the catalog.

## Definitions and contracts

### Finding

`DuplicateFinder.groups(in tracks: [TrackFacts]) -> [DuplicateGroup]` where `TrackFacts` is the small value the finder needs (id, title, artist name, album name, duration, content hash, file URL, format, bitrate, sample rate, bit depth, size, added date). Pure and synchronous; the view model builds the facts from the repositories.

Two passes:

1. **Hash groups.** Tracks sharing a non-null `contentHash` form a group with `reason: .identicalBytes`. These are certain.
2. **Tag groups** over everything not already grouped. Key = normalised title + normalised artist + duration rounded to the nearest second, and groups also match when durations differ by at most one second (a bucket join, not exact equality: 180.9 and 181.0 are the same song). `reason: .matchingTags`.

Normalisation (`DuplicateFinder.normalise(_:)`, tested on its own): lowercase; Unicode NFKD with combining marks stripped; punctuation and bracketed suffixes removed (`(Remastered 2015)`, `[Live]`, `- Single Version`); `feat.`, `ft.`, `featuring` and everything after them dropped; whitespace collapsed. A group's `representativeTitle` and `representativeArtist` come from the keeper, not from the normalised key.

### Choosing

`DuplicateFinder.rankKeeper(in group:) -> TrackFacts.ID` proposes the copy to keep, by this order, first difference wins:

1. Not damaged (see below) over damaged.
2. Lossless over lossy.
3. Higher bitrate.
4. Higher sample rate, then bit depth.
5. Larger file.
6. Earliest `addedAt` (the user's own rip predates the cloud copy in the case that started this).

The proposal is a default selection, never automatic. Each copy row shows: format, bitrate, sample rate and bit depth, size, duration, the path relative to its library root, date added, and a damage badge.

**Damage** is what FFmpeg reports when decoding the file to nowhere: a count of decoder errors. It is expensive (a full decode), so it is computed lazily per group when the group is expanded or selected, off the main actor through the existing `FFmpegDecoder`, cached for the sheet's lifetime, and shown as "Damaged, N errors" beside the copy. It must never block the list.

### Acting

| Action | Scope | Effect |
|---|---|---|
| Keep this one | group | Trashes every other copy in the group through `TrackFileDeleter`, disables each row only after its trash succeeds, prunes orphans once, removes the group from the list, selects the next group. One confirmation naming the count. |
| Move to Trash | copy | Trashes that copy; the group shrinks; a group of one disappears. |
| Remove from library | copy | Today's soft delete, kept for a file that must stay on disk; the help text says the next scan will bring it back if the file remains. Prunes orphans. |
| Reveal in Finder | copy | `NSWorkspace.activateFileViewerSelecting`. |
| Play | copy | Plays that file now, so the user can hear the difference. |

Failures follow the existing escalation: a failed trash offers "Delete Permanently" with the error, through `confirmPermanentDelete`. A copy whose row is disabled after a trash that the FSEvents watcher also disables is fine; both writes are idempotent.

### TrackFileDeleter (Library module)

```swift
public actor TrackFileDeleter {
    public init(rootRepository: LibraryRootRepository, fileOperations: FileOperations = .system)
    /// Trashes the file under the root scope that covers it, or the per-file
    /// bookmark when none does. Throws LibraryError on a stale bookmark or a
    /// failed trash; never touches the database.
    public func trash(_ track: Track) async throws
    public func remove(_ track: Track) async throws
}
```

`FileOperations` is the injectable pair (`trashItem`, `removeItem`) that `SystemTrackFileDeleter` already models in the UI module; it moves here. `LibraryViewModel+Delete` keeps its outcome enum and batch orchestration and calls this actor for the file step. That fixes the scope gap in the existing Delete from Disk paths as a side effect, and it is called out in the changelog as such.

### Staying put

- `DuplicateGroup.id` is derived from its reason and its sorted member ids, so a group keeps its identity across updates. No `UUID()` per construction.
- `removeCopies(ids:)` on the view model edits `groups` in place: drops the copies, drops groups that fall below two, never flips `isLoading`, never re-fetches. A full `load()` runs only on open and on an explicit Refresh button.
- The sheet keeps `selectedGroupID`; after a group action it advances to the next group in the current (filtered) order.

### Search

A `.searchable`-style field at the top of the sheet filtering groups whose keeper title, artist, album or any copy's path contains the query, case and diacritic insensitive. The count line reads "N groups, M copies" (plural keys) for the filtered set.

### Accessibility identifiers

`A11y.DuplicateReview`: `sheet`, `search`, `refresh`, `group(id)`, `copy(id)`, `keeperRadio(id)`, `keepButton(id)`, `trashButton(id)`, `removeButton(id)`, `revealButton(id)`, `playButton(id)`, `damageBadge(id)`, `close`. Computed identifiers follow `A11y.LibrarySummary`'s pattern.

## Implementation plan

Five slices, one commit each, gates green (`make format`, `make lint`, `make build`, `make test-coverage`, `make test-library`, `make test-ui`).

1. **DuplicateFinder.** Models, normalisation, hash and tag passes, keeper ranking, tests. No UI change.
2. **TrackFileDeleter.** The actor with root-scope and per-file-bookmark handling, tests with a temp root and a fake scope; `LibraryViewModel+Delete` rewired to it; `removeTrack(id:)` prunes orphans.
3. **View model.** Facts from the repositories, `DuplicateFinder` grouping, stable ids, in-place removal, keeper action, search, lazy damage scan. Tests.
4. **Sheet.** Search field, richer rows, keeper radio, actions with confirmations, identifiers, help, catalog keys and plurals, pseudolocale, snapshots. Update or retire the centring source test.
5. **E2E and docs.** `DuplicateReviewTests` against fixture copies (the seeder duplicates two fixture files under new names), the menu invocation test by identifier, changelog, README, website, ADR index.

Slices 1 and 2 are independent. 3 needs 1. 4 needs 2 and 3. 5 needs 4.

## Behavioural definitions

- **Given** two files with identical bytes under different names, **when** the tool loads, **then** they form one group with reason "identical bytes", whatever their tags say.
- **Given** "All Apologies" at 3:52 and "all apologies (remastered)" at 3:53 by the same artist, **when** the tool loads, **then** they form one group with reason "matching tags".
- **Given** a 320 kbps MP3 cloud copy and the user's own FLAC of the same song, **when** the group is shown, **then** the FLAC is the proposed keeper.
- **Given** a group with a proposed keeper, **when** the user clicks Keep this one and confirms, **then** the other copies are in the Trash, their rows are disabled, the group is gone from the list, the next group is selected, and the scroll position has not moved.
- **Given** a copy whose folder is a bookmarked library root, **when** it is trashed in the sandboxed Debug build, **then** the trash succeeds because the root scope was held for the operation.
- **Given** a copy the decoder cannot fully read, **when** its group is selected, **then** a damage badge with the error count appears beside it within a few seconds, and the list never stalls meanwhile.
- **Given** the user types "nirvana" in the search field, **then** only groups with that artist, title, album or path remain, and the count line updates.
- **Given** a file was removed from the library but left on disk, **when** the next scan runs, **then** it is back in the library, and the tool's help text said so.

## Context7 lookups

- Foundation `FileManager.trashItem(at:resultingItemURL:)` on macOS: behaviour under the App Sandbox, and whether it requires access to the parent directory (it does; confirm the current documentation).
- `String` Unicode normalisation in Swift: `decomposedStringWithCompatibilityMapping` and `folding(options:locale:)` for diacritic-insensitive matching.
- SwiftUI `List` selection with `Section` on macOS 15, and `ScrollViewReader.scrollTo` for advancing to the next group.

Always take the latest documented API; if a lookup shows any of the above deprecated on macOS 15, stop and ask.

## Dependencies

No new packages. No schema change: `content_hash` and `file_bookmark` already exist. No new entitlements.

## Test plan

- **Library:** `DuplicateFinderTests` (hash groups win over tags; normalisation cases: diacritics, brackets, feat., duration ±1 s; keeper ranking per rule; null hashes fall through to tags). `TrackFileDeleterTests` (trash under a temp root with a fake scope provider; stale bookmark throws `LibraryError.bookmarkStale`; per-file fallback used when no root covers the file).
- **UI:** `DuplicateReviewViewModelTests` (in-place removal keeps other groups' identities; a group of one disappears; keeper action orders trash before disable; search filters and counts; `isLoading` never flips after load). Snapshots light, dark, increased contrast with three groups. `L10nTests` plural entries for the count keys.
- **E2E:** `DuplicateReviewTests` on fixture copies: open from the Tools menu by identifier, search narrows, Keep this one trashes and advances, scroll position unchanged (compare the first visible row before and after). Registry rows in `SurfaceCompletenessTests`.
- **Audits:** `IdentifierAuditTests` and `Scripts/audit-help-text.py` pass without allowlist additions.

## Acceptance criteria

- Byte-identical copies are found regardless of tags; tag matches survive punctuation, diacritics, bracketed suffixes and a one-second duration difference.
- Each copy shows enough to choose; a keeper is proposed by the documented ranking.
- Keep this one trashes the rest under the correct scope, in Debug and release, and the next scan does not resurrect them.
- Acting on a group never scrolls the list or shows a spinner; the next group is selected.
- Search works on title, artist, album and path.
- The existing Delete from Disk paths hold the root scope, and the changelog says so.
- All controls have identifiers and localized help; all gates green; docs updated.

## Gotchas

- **The rescan resurrection.** Any design that leaves the file on disk does not fix a duplicate. Say so in the Remove from library help text.
- **Trash needs the folder's scope, not the file's.** `trashItem` writes to the parent directory. Acquire the root scope; a per-file bookmark is the fallback for files outside every root, and may itself be stale (renew it the way `MetadataEditService.readTags` does).
- **Null hashes.** The backfill may not have reached every track; such tracks can only be matched by tags. Do not wait for the backfill in the tool.
- **`DuplicateGroup.id = UUID()`** is the current bug behind the scroll reset; replace it, do not paper over it with scroll restoration.
- **Damage scan cost.** A full decode per copy. Lazy, per selected group, cancelled when the sheet closes, never on the main actor, results cached by track id.
- **The centring source test** reads the sheet's source and counts frame modifiers; restructuring the sheet breaks it. Update it in the same slice.
- **Plurals.** "%lld groups found" already has a plural variant; the new count keys need them too or the en-XA gate fails.
- **iCloud copies are real tracks.** A four-letter name is not evidence of junk; a few are the only copy of a bonus track. The tool proposes, the user decides.

## Handoff

- **Acoustic duplicates.** Group by AcoustID fingerprint match for different masters of one recording.
- **Merge history into the keeper.** Sum play counts, keep the higher rating and the loved flag when trashing copies.
- **Rules.** "Prefer my rips over cloud copies" as a saved preference that pre-selects keepers across all groups, with one confirmation for the lot.
- **Library Summary hook.** A duplicates count in the hygiene tab that opens this tool pre-filtered.
