# ADR-076: Listening Behaviour

> Prerequisites: ADR-001 to ADR-075 complete. `play_history` (M001) is the local,
> canonical per-play log: `PlayHistoryRecorder` writes one row per play at
> the Last.fm threshold (>= 50% consumed or 4 minutes) and increments
> `skip_count` otherwise, so "a play means more than half listened" is
> already the counting rule. The Library Summary window (#373) has four live
> tabs; this ADR builds the fifth.
>
> Read `docs/design-spec/_standards.md` first.

## The brief

Surface how the library actually gets listened to, and backfill years of
history from a Last.fm export. Much of an export is music the library does
not hold, so imported history must survive unmatched and link up later.

## Slices

### ADR-076 slice 1: Last.fm import (shipped with this document)

- Migration M035: `imported_listens` (source, played_at UTC epoch, artist,
  title, album, track_mbid, nullable track_id, unique identity index so
  re-imports are idempotent).
- `ListenImportRepository`: idempotent batch insert; `rematch()` links rows
  by MusicBrainz track id first, then tiered-normalised artist+title (exact,
  then typography folding for curly quotes and dashes, then edition-suffix
  stripping such as "- 2015 Remaster" on either side; strictest tier wins),
  and drops matched rows within 300 s of a local play of the same track (the
  export echoes what Bòcan itself scrobbled); `counts()`; `removeAll()` as
  the one-statement undo. Tier yields were measured against a real 63k-row
  export before being built.
- `LastFMExportParser` (Library): RFC 4180 tokenizer, header-driven on the
  official export shape (`uts,utc_time,artist,artist_mbid,album,album_mbid,
  track,track_mbid`). `uts` is trusted; `utc_time` ignored. Broken rows are
  counted, never fatal. Beware: CRLF is a single Swift `Character`.
- `ListeningHistoryImporter` (Library): read, parse, chunked insert,
  re-match, toast-ready summary.
- UI: Tools menu item + the Listening Behaviour tab's Imported History
  section (import, Match Again, Remove behind a confirmation, live spinner).
- Imports never mutate `play_count`, `last_played_at`, or `play_history`:
  local counters stay canonical, Recently Played stays sane, and the whole
  import is reversible.

### ADR-076 slice 2: Counter analytics (no import required, richer with one)

- Skip rate per track (skip_count vs play_count; both already threshold
  -weighted), sorted worst-first: the delete-candidates list, with
  `skip_after_seconds` as the average bail-out point.
- Library utilisation (% of tracks ever played) and a Gini coefficient over
  play counts; lifetime figures may add matched imported listens, clearly
  labelled.
- Dormant favourites: high lifetime plays, nothing in 24 months (local
  last_played_at and matched imports both count).
- Album completion: albums where only the leading track numbers were ever
  played.

### ADR-076 slice 3: Time analytics (built on play_history + imported_listens)

- Hour x weekday heatmap over the union of local and imported plays.
  Timestamps are UTC; render in the current local timezone and say so in a
  footer.
- Discovery rate: first-seen artists per month as a line (imported rows
  count by artist text, so unmatched history still contributes).
- Seasonality: tracks or artists with a strong single-month skew across
  years.
- Genre by time of day (matched plays only; stretch).

## Non-goals

- No mutation of local play counters from imports, ever.
- No scrobble submission changes; this ADR only reads history.
- No fuzzy matching beyond tiered normalisation (no edit distance); Match
  Again plus a growing library covers the long tail honestly.
