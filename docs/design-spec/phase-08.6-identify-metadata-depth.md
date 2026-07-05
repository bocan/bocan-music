# Phase 8.6 - Identify Track: Metadata Depth & Release Choice

> Prerequisites: Phase 8.5 (AcoustID Fingerprinting) complete.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Finish what Phase 8.5's gotchas section promised: "a MusicBrainz recording often has
many releases (original, remaster, various territories). Surface the release list with
enough info for the user to pick the right one."

Today the identify pipeline silently uses `releases.first` and discards the rest, and
the field grid stops at 8 basic tags even though the tag writer, the DB schema (M002),
and the MusicBrainz response all already support far more. This phase surfaces the
discarded data with progressive disclosure: casual users see exactly what they see
today; taggers can pick a specific release and apply identifiers.

Three design decisions are settled (2026-07-05, discussed with maintainer):

1. **Release choice = popover picker.** The expanded candidate row shows the selected
   release as a compact menu-style control ("Abbey Road · 1969 · UK · Apple", with a
   count when more than one exists). Clicking opens a popover listing every release
   with date, country, label, catalog number, and status. Picking one re-populates the
   field grid. Default selection: smartest release, not blindly the first (see
   Implementation plan step 3).
2. **Extra fields live behind a "Show advanced fields" disclosure** in the field grid.
   Primary tier stays today's 8 fields. Advanced tier: ISRC, track total, disc total,
   and the MusicBrainz IDs. Advanced fields default to **ticked when the file has no
   current value** (pure gain, no overwrite risk) and unticked otherwise.
3. **Label and catalog number are display-only.** They inform the release choice in
   the picker but are not applyable and get no new tag/DB plumbing in this phase.

## Non-goals

- Label / catalog number write-back (no `TrackTags` field, no DB column) - future
  phase if searching by label ever matters.
- Batch identify / auto-tagging entire libraries - unchanged from 8.5, never.
- Cover art from the Cover Art Archive - tempting neighbour, separate phase.
- Submitting fingerprints to AcoustID - still out of scope.
- Full release-date precision (month/day) as an applyable tag - `TrackTags.year` stays
  an `Int`; the full date string is display-only context in the release picker.

## Outcome shape

No new files; the phase deepens existing ones.

```
Modules/Acoustics/Sources/Acoustics/
├── MusicBrainzClient.swift        # inc= gains isrcs+labels+media (verify labels reach
│                                  #   label-info; today label is likely always nil)
├── MBRecording.swift              # decode country, catalogNumber, media totals, ISRCs
└── FingerprintResult.swift        # IdentificationCandidate.releases: [ReleaseOption]

Modules/Library/Sources/Library/
├── Fingerprint/FingerprintService.swift  # build ALL ReleaseOptions, rank default
└── Edit/TrackTagPatch.swift              # + isrc?, MBID fields (see contracts)

Modules/UI/Sources/UI/Fingerprint/
├── CandidatePickerView.swift      # release picker control + advanced disclosure
├── ReleasePickerPopover.swift     # NEW: the popover release list
└── ViewModels/IdentifyTrackViewModel.swift  # IdentifyTagField gains advanced cases
```

## Schema

**None.** M002 already added `isrc`, `musicbrainz_track_id`,
`musicbrainz_recording_id`, `musicbrainz_release_id`, `musicbrainz_release_group_id`,
`musicbrainz_album_artist_id` to `tracks`. `TagReader`/`TagWriter` already round-trip
all of them. This phase only connects existing plumbing.

## Implementation plan

Three commits, each gates-green:

### Commit A - Acoustics: keep what MusicBrainz sends

1. **`MusicBrainzClient`**: extend `inc=` to `releases+artists+tags+isrcs+labels+media`.
   Verify against a freshly recorded fixture that `label-info` and `media` actually
   populate (today's `inc=` likely never returns label-info, meaning
   `candidate.label` has been silently nil in production - confirm and note in the
   commit message).
2. **`MBRecording`**: decode `country`, `label-info[].catalog-number`, `media[]`
   (format, `track-count`, position, and this recording's track number within each
   medium), `isrcs`, `release-group` id. All optional; absent keys must not fail
   decoding (MusicBrainz omits liberally).
3. **`FingerprintService.buildCandidate`**: build one `ReleaseOption` per release
   instead of collapsing to `.first`. Rank for the default selection: prefer
   `status == "Official"`, then earliest release date, then release-group type
   "Album" over compilation/single. The candidate keeps top-level convenience fields
   derived from the default release so existing callers and tests stay valid.

### Commit B - patch plumbing: make identifiers applyable

4. **`TrackTagPatch`**: add `isrc` is already present; add `musicbrainzTrackID??`,
   `musicbrainzRecordingID??`, `musicbrainzReleaseID??`, `musicbrainzReleaseGroupID??`,
   `musicbrainzAlbumArtistID??`, `trackTotal`/`discTotal` are already present.
   Extend `isEmpty` accordingly.
5. **`EditTransaction`**: map the new patch fields into `TrackTags` (file write) and
   the `tracks` row update (DB write) - both arms, same atomic transaction as today.
6. Round-trip tests: patch → file → re-read → DB row, for every new field, per
   container format the suite already exercises (MP3/ID3, FLAC/Vorbis, M4A).

### Commit C - UI: progressive disclosure

7. **`IdentifyTagField`**: new cases `isrc`, `trackTotal`, `discTotal`,
   `mbRecordingID`, `mbReleaseID`, `mbReleaseGroupID`, `mbAlbumArtistID`, plus a
   `tier: Tier` (`.primary` / `.advanced`) property. Display names localized; MBID
   values render in a monospaced truncating style.
8. **Release picker**: compact control in the expanded row (menu-style, shows title ·
   year · country · label, plus "1 of N"). Popover lists all `ReleaseOption`s -
   columns: title, date, country, label, catalog number, status badge. Selection is
   per-candidate `@State`; changing it recomputes the grid's proposed values and
   re-runs the default-tick logic. Keyboard: arrow keys move, Return selects,
   Escape closes (popover default behaviour; verify, don't fight it).
9. **Advanced disclosure**: `DisclosureGroup`-style toggle under the primary grid,
   labelled "Show advanced fields (N)". Collapsed by default, per-candidate state.
   Advanced default ticks: ticked when current file value is empty, else unticked.
10. **Apply**: unchanged path (`MetadataEditService`), now with the wider patch. The
    applied release's IDs (release, release-group, album-artist) come from the
    *selected* release, not the recording's first.
11. Snapshots: add expanded-row states - single release, multi-release with picker,
    advanced tier open. Light + dark. Convention tests: tier split exists, popover
    file exists, default-tick rule for advanced fields.
12. `make pseudolocale` after adding catalog keys.

## Definitions & contracts

### `ReleaseOption`

```swift
public struct ReleaseOption: Sendable, Identifiable, Hashable {
    public let id: String                 // MB release ID
    public let title: String
    public let date: String?              // full "YYYY-MM-DD" when MB has it
    public let year: Int?
    public let country: String?
    public let status: String?            // Official / Promotion / Bootleg / …
    public let label: String?             // display-only
    public let catalogNumber: String?     // display-only
    public let albumArtist: String?
    public let albumArtistMBID: String?
    public let releaseGroupID: String?
    public let trackNumber: Int?          // this recording's position in this release
    public let discNumber: Int?
    public let trackTotal: Int?
    public let discTotal: Int?
    public let mediaFormat: String?       // CD / Vinyl / Digital … display-only
}
```

### `IdentificationCandidate` (revised)

Keeps every existing stored property (top-level fields now derived from the default
release) and adds:

```swift
public let isrcs: [String]            // usually 0 or 1; apply the first
public let releases: [ReleaseOption]  // ranked, default first
```

## Context7 lookups

- `use context7 SwiftUI popover attachmentAnchor macOS`
- `use context7 SwiftUI DisclosureGroup custom label style`

(MusicBrainz `inc=` semantics are documented at musicbrainz.org/doc/MusicBrainz_API,
not Context7 - record fixtures rather than trusting memory.)

## Test plan

- **Acoustics**: new fixture `mb_recording_response_multi_release.json` (recorded from
  the live API once, committed) with ≥3 releases across statuses/countries; assert
  every `ReleaseOption` field decodes; assert ranking (Official-then-earliest); assert
  absent keys decode to nil. ISRC fixture arm.
- **Library**: `buildCandidate` produces one option per release; default ranking
  stable; candidate top-level fields equal default release's.
- **Metadata/Edit round-trip**: each new patch field written to file + DB and re-read
  equal, per format.
- **UI**: snapshots per step 11; convention tests per step 11; L10n en-XA coverage
  green (`make pseudolocale`).
- No network in any test (unchanged rule).

## Acceptance criteria

- [ ] A recording with multiple releases shows the picker control with an accurate
      count; the popover lists them with date/country/label/cat#/status.
- [ ] Changing the release changes album/year/track#/disc#/totals/IDs in the grid.
- [ ] Advanced disclosure reveals ISRC, totals, and MBIDs; collapsed by default.
- [ ] Advanced fields default ticked only when the file's current value is empty.
- [ ] Applying writes selected fields to file bytes AND the DB row atomically
      (existing `EditTransaction` guarantees); MBIDs verified by re-reading the file.
- [ ] Label/catalog number visibly inform the release choice but are not applyable.
- [ ] `inc=` expansion respects the 1 req/s MusicBrainz limit (no extra requests -
      same single lookup, bigger response).
- [ ] Existing 8-field flow is pixel-stable when the user never touches the new
      affordances (casual-user path unchanged).
- [ ] `make lint && make test-coverage && make test-ui` green; ≥80% Acoustics
      coverage holds.

## Gotchas

- **`label-info` needs `inc=labels`.** The current code decodes it but likely never
  receives it - treat "label was always nil" as a probable latent bug to confirm in
  Commit A, and re-record fixtures rather than hand-editing them.
- **Bigger responses, same rate limit.** `inc=media+isrcs+labels` fattens the payload
  substantially for prolific recordings (a Beatles track can have dozens of releases).
  Cap the picker list at the response's contents - do NOT page through
  `browse` endpoints (that would multiply requests against the 1 req/s limit).
- **MusicBrainz omits keys freely.** Every new decoded field must be optional and
  tested against a fixture with the key absent, or a niche release will crash decoding
  for everyone.
- **MBID grid rows are UUIDs.** Truncate middle, monospaced, `textSelection(.enabled)`
  so Picard users can copy them; VoiceOver labels say "MusicBrainz recording ID", never
  read the UUID digits.
- **Default-tick asymmetry is deliberate.** A missing ISRC/MBID is a safe add; an
  existing one differing from the proposal usually means the file was tagged against a
  different release on purpose - so it defaults unticked. Do not "simplify" to the
  primary tier's diff-based rule.
- **Per-candidate state**: expanded release selection and disclosure state must key by
  candidate id (the existing `fieldSelection` dictionary pattern), or expanding a
  second candidate inherits the first's choices.

## Handoff

- Scrobbling (Phase 13) can start sending `musicbrainz_recording_id` for identified
  tracks once users apply MBIDs - no code change there, the column simply gets data.
- A future "label / catalog number first-class" phase has its display groundwork done
  (ReleaseOption carries both); it would add TagLib keys, `TrackTags`/patch fields, a
  migration, and two grid rows.
- A future Cover Art Archive phase can key off `ReleaseOption.id` directly.
