# Phase 7 — Smart Playlists

> Prerequisites: Phases 0–6 complete. Manual playlists work.
>
> Read `phases/_standards.md` first.

## Goal

Rule-based playlists that auto-update as the library changes. A rule builder UI with nested groups, a deterministic criteria-to-SQL compiler, live updates, and a set of sensible presets.

## Non-goals

- Cross-field computed columns (e.g. "artist has > N tracks") — out of scope for v1.
- User-defined SQL mode — never. Stay safe.
- Sync/export of smart criteria to other apps — Phase 14 handles M3U only.

## Outcome shape

```
Modules/Library/Sources/Library/SmartPlaylists/
├── SmartPlaylist.swift                 # Public API
├── Criteria/
│   ├── SmartCriterion.swift            # Enum recursion
│   ├── Field.swift                     # Typed field catalogue
│   ├── Comparator.swift
│   ├── Value.swift                     # Typed values (string, number, date, bool, duration, enum)
│   └── LogicalOp.swift
├── Compiler/
│   ├── CriteriaCompiler.swift          # Criteria -> SQL AST
│   ├── SQLBuilder.swift                # AST -> parameterised SQL
│   ├── FieldDefinitions.swift          # (Field -> column path, allowed comparators, value type)
│   └── Validator.swift                 # Structural + type checks
├── Execution/
│   ├── SmartPlaylistService.swift      # CRUD + execution
│   └── SmartObservation.swift          # DB change triggers -> playlist re-emission
├── Presets/
│   └── BuiltInSmartPresets.swift
└── Errors.swift

Modules/UI/Sources/UI/Playlists/Smart/
├── RuleBuilderView.swift
├── RuleRowView.swift
├── GroupRowView.swift
├── LimitAndSortView.swift
└── SmartPresetPicker.swift
```

## Implementation plan

1. **Typed field catalogue** — enumerate every field that can participate in a rule:
   - Text: `title`, `artist`, `album_artist`, `album`, `genre`, `composer`, `comment`.
   - Numeric: `year`, `track_number`, `disc_number`, `play_count`, `skip_count`, `rating` (0–100), `bpm`, `bitrate`, `sample_rate`, `bit_depth`.
   - Duration: `duration`.
   - Date: `added_at`, `last_played_at`.
   - Bool: `loved`, `excluded_from_shuffle`, `is_lossless`, `has_lyrics`, `has_cover_art`.
   - Enum: `file_format` (one of the known codecs).
   - Membership: `in_playlist`, `not_in_playlist`, `in_folder` (filesystem path prefix).
   - MBID presence: `has_musicbrainz_release_id`.

   Each field has: allowed comparators, value type, SQL expression (including any JOINs required).

2. **Comparators**:
   - Text: `is`, `is_not`, `contains`, `does_not_contain`, `starts_with`, `ends_with`, `matches_regex`, `is_empty`, `is_not_empty`.
   - Numeric: `=`, `≠`, `<`, `>`, `≤`, `≥`, `between`, `is_null`, `is_not_null`.
   - Duration: same as numeric with value in seconds.
   - Date: `before`, `after`, `on`, `between`, `in_last_days`, `in_last_months`, `in_last_years`, `is_null`, `is_not_null`.
   - Bool: `is_true`, `is_false`.
   - Membership: `member_of(playlist_id)`, `not_member_of(playlist_id)`, `path_under(folder)`.

3. **`SmartCriterion`** recursive enum:
   ```swift
   public indirect enum SmartCriterion: Sendable, Codable, Hashable {
       case rule(Rule)
       case group(LogicalOp, [SmartCriterion])   // non-empty children

       public struct Rule: Sendable, Codable, Hashable {
           public let field: Field
           public let comparator: Comparator
           public let value: Value
       }
   }

   public enum LogicalOp: String, Sendable, Codable { case and, or }
   ```

4. **`Validator`** — rejects malformed criteria before persistence:
   - Comparator must be valid for the field's type.
   - `Value` type must match the field (enforced by `Value` being a typed enum, but double-check on decode).
   - `between` has ordered low/high.
   - `matches_regex` value compiles as an NSRegularExpression; if not, throw.
   - Nested groups aren't empty (a group with zero children is nonsense).

5. **`SQLBuilder`** — compiles a validated criteria tree into:
   ```swift
   public struct CompiledCriteria: Sendable {
       public let selectSQL: String         // "SELECT tracks.id FROM tracks LEFT JOIN ... WHERE ..."
       public let arguments: StatementArguments
       public let joins: Set<Join>          // used for DatabaseRegion for observation
   }
   ```
   - **All values are bound**, never string-interpolated. No exception.
   - `contains`/`starts_with` use `LIKE` with escaped `%` and `_` and `ESCAPE '\\'`.
   - `matches_regex` uses SQLite's `REGEXP` operator after we install a custom function via GRDB (`Database.add(function:)`). The function uses `NSRegularExpression`. Document the match semantics (unanchored; ICU-ish).
   - `is_null` / `is_not_null` use `IS NULL` / `IS NOT NULL`.
   - Joins added lazily: `in_playlist(pid)` joins `playlist_tracks` with a parameter; `path_under(prefix)` uses `LIKE prefix || '%'` against `file_url`.
   - Nested groups produce `(... AND ...)` / `(... OR ...)` with correct precedence.

6. **Limit & sort** — a separate structure, not part of the tree:
   ```swift
   public struct LimitSort: Sendable, Codable, Hashable {
       public var sortBy: SortKey = .addedAt
       public var ascending: Bool = false
       public var limit: Int? = nil
       public var liveUpdate: Bool = true
   }
   public enum SortKey: String, Codable, Sendable {
       case title, artist, album, year, addedAt, lastPlayedAt, playCount, rating, duration, bpm, random
   }
   ```
   - `random` uses a **seeded** random in SQLite (`ORDER BY abs(hash(id, seed))` approximation) so the order is stable until the user refreshes. Store seed in the playlist row.

7. **`SmartPlaylistService`**:
   ```swift
   public actor SmartPlaylistService {
       public func create(name: String,
                          criteria: SmartCriterion,
                          limitSort: LimitSort,
                          parentID: Int64? = nil) async throws -> Playlist
       public func update(id: Int64, criteria: SmartCriterion, limitSort: LimitSort) async throws
       public func tracks(for id: Int64) async throws -> [Track]
       public func observe(_ id: Int64) -> AsyncThrowingStream<[Track], Error>
   }
   ```
   - Persists criteria and limit-sort as two separate JSON columns (`smart_criteria`, `smart_limit_sort`) on `playlists`. Add columns via a migration `M003_SmartLimitSort` if not already present.

8. **Observation** — use the `CompiledCriteria.joins` to construct a `DatabaseRegion` covering exactly the tables/columns the query depends on. GRDB's `ValueObservation` fires only when relevant rows change. If any criterion involves `last_played_at` / `play_count` (which change on every play), the observation may re-emit often; debounce 250ms.

9. **Rule builder UI**:
   - Mirrors Music.app: top-level checkbox "Match [all|any] of the following rules"; rows with `[field ▾] [comparator ▾] [value]`; `+` to add, `−` to remove, `•••` to open a sub-group. Sub-groups render with a bracket on the left.
   - Field picker grouped by category (Text / Numbers / Dates / Flags / Membership).
   - Value control morphs with type: text field, number stepper, date picker, enum menu, duration picker (`HH:MM:SS`), playlist picker.
   - `between` shows two value controls.
   - Validation errors inline: invalid regex, empty group, between reversed.

10. **Presets** — insert on first run (keyed so they don't re-create if deleted):
    - **Recently Added** — `added_at in_last_days 30`, sort by added_at desc.
    - **Top 25 Most Played** — sort by play_count desc, limit 25, `play_count > 0`.
    - **Unrated** — `rating is_null`, sort by added_at desc.
    - **Loved** — `loved is_true`.
    - **Never Played** — `last_played_at is_null`.
    - **Five Stars** — `rating = 100`.
    - **High Bitrate** — `is_lossless is_true`.

11. **Execution modes**:
    - `liveUpdate = true` (default): playlist contents recompute on relevant changes.
    - `liveUpdate = false`: snapshot at creation/edit time, stored via `playlist_tracks` like a manual playlist. Makes sense for "once-a-week favourite" workflows. This is the same storage path as manual — treat it as a hybrid that runs the query on demand and replaces `playlist_tracks` atomically.

12. **Add-to-playlist behaviour** — disabled for smart playlists (their contents are derived). Context menu items involving manual mutation hide.

## Definitions & contracts

### `Field` sketch

```swift
public enum Field: String, Sendable, Codable, Hashable, CaseIterable {
    case title, artist, albumArtist, album, genre, composer, comment
    case year, trackNumber, discNumber, playCount, skipCount, rating, bpm, bitrate, sampleRate, bitDepth
    case duration
    case addedAt, lastPlayedAt
    case loved, excludedFromShuffle, isLossless, hasLyrics, hasCoverArt
    case fileFormat
    case inPlaylist, notInPlaylist, pathUnder
    case hasMusicBrainzReleaseID

    public var dataType: DataType { /* lookup table */ }
    public var allowedComparators: [Comparator] { /* lookup table */ }
    public var sqlExpression: SQLExpression { /* column reference + required joins */ }
}
```

### `Value`

```swift
public enum Value: Sendable, Codable, Hashable {
    case text(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case duration(TimeInterval)
    case range(Value, Value)
    case playlistRef(Int64)
    case enumeration(String)
    case null
}
```

## Context7 lookups

- `use context7 GRDB Database add function REGEXP`
- `use context7 GRDB StatementArguments parameterised bind`
- `use context7 GRDB DatabaseRegion ValueObservation`
- `use context7 SwiftUI nested form rule builder`
- `use context7 Swift Codable indirect enum recursive`

## Dependencies

None new.

## Test plan

### Compiler

- For each field × comparator combination, compile a minimal rule and verify the generated SQL + bindings exactly (golden files under `Tests/Fixtures/smart/`).
- Nested groups compile with correct parenthesisation: `(a AND (b OR c))`.
- All values round-trip via binding — no string interpolation anywhere (inspect the generated SQL for literal digits/strings beyond punctuation and expected keywords).
- Regex function registered; matches/doesn't match expected strings.
- `between` reversed throws a validation error before reaching SQL.
- `in_last_days(30)` computes the cutoff `now - 30d` at query time using SQLite's `unixepoch('now','-30 days')` rather than baking a timestamp into the query.

### Execution

- A playlist with "rating ≥ 80" returns exactly the tracks with rating ≥ 80 after a pool of inserts.
- Changing a matching track's rating to below the threshold causes the observation stream to emit a new list.
- Limit/sort honoured across re-emissions.
- `random` sort produces a stable order within a session; regenerating the seed shuffles.

### UI

- Rule builder round-trip: build a criteria tree in the UI, save, reopen — identical structure.
- Type morphing: changing the field updates available comparators and value control.
- Invalid regex shows an inline error; Save button disabled.

### Security

- A rule with `title contains ' OR 1=1 --` yields zero matches, not a library-wide dump. (Canonical SQL-injection attempt test — belt and braces.)
- All generated SQL is bound-argument only; a test walks the `CompiledCriteria.selectSQL` string and asserts it contains no user-provided substrings.

### Performance

- Compile + execute on a 10k-track library < 100ms for a typical 3–5-rule playlist.
- A playlist with a regex rule compiles a cached `NSRegularExpression`; consecutive executions don't re-compile.

## Acceptance criteria

- [ ] Create "5-star rock from the 70s, played < 5 times" in the UI; results match expectations on a seeded fixture library.
- [ ] Live update: change a track's play count, smart playlist list updates within 1s.
- [ ] Preset playlists exist on first run.
- [ ] No raw user-provided strings ever reach SQL unbound.
- [ ] Validator catches every structural mistake the UI can encode.
- [ ] 80%+ coverage on compiler + service.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **Date arithmetic** in SQLite: stick to `unixepoch('now', '-N days')`. Don't precompute in Swift; that causes staleness in long-running apps.
- **Regex semantics**: NSRegularExpression is ICU-based; users coming from PCRE may hit differences. Document, or expose a "simple contains" comparator as the primary UI and hide regex under an "Advanced" disclosure.
- **`LIKE` case sensitivity**: SQLite's default is case-sensitive for non-ASCII. Either enable `PRAGMA case_sensitive_like = OFF` (breaks indexes) or use a custom collation. Prefer: lowercase both sides via `LOWER()` (slower, but correct).
- **Re-emission storms**: a criterion on `play_count` fires on every scrobble. Debounce the observation's output stream and coalesce consecutive updates.
- **JSON encoding** for criteria: `SmartCriterion` is an `indirect enum`. Ensure `Codable` emits a discriminator; GRDB stores the JSON string blob. Pin the encoding format in a test so schema evolution doesn't silently break existing rows.
- **Recursive UI**: nesting too deep becomes unusable. Cap at 3 levels via validator; document.
- **Field removal**: if a future version removes a field, existing criteria must decode gracefully. Add a `case unknown(raw: String)` decode path and surface as "Invalid rule" in the UI.
- **`in_playlist`** against a smart playlist: forbid to avoid infinite recursion. Validator check.
- **`path_under` + sandbox**: the stored `file_url` is the absolute path captured at scan time. If the root moves, path prefixes break. Document; UI may offer a "pick folder" that writes the current root, not a free-text path.
- **Limit + observation**: GRDB's `ValueObservation` doesn't natively support LIMIT-awareness (it observes whole tables). That's fine — we just re-run the query. Don't micro-optimise.
- **Duplicate presets**: identify presets by a stable `preset_key` text column so deleted ones don't re-appear but edited ones also aren't reset. Add column via migration if not present.

## Handoff

Phase 8 (Metadata Editor) expects:

- The field catalogue is the canonical list of editable fields; the editor UI should render from the same source of truth so adding a field in one place surfaces in the other.
- `SmartPlaylistService.observe` returning a live stream plays nicely with the editor's "save → preview update" flow.
