# Maintainability Audit -- Findings Ledger

The durable record of the audit. **Every cluster considered gets a row**, in all
four outcomes, so nothing is silently dropped and no future audit re-litigates a
decision already made. Append as you go; never delete a row.

Read the method and the decision rubric in [README.md](README.md) first.

## How to fill this in

- **ID**: `S<session>-<n>`, e.g. `S1-3` for the third cluster considered in
  Session 1.
- **Location(s)**: `file:line` for each copy, or a directory + pattern if many.
- **Kind**: from the taxonomy (near-duplicate-fn, copy-paste-block,
  parallel-types, boilerplate-wrapper, repeated-literal, test-scaffolding).
- **Copies / lines**: how many copies and roughly how many lines each, plus the
  normalized-diff overlap if measured (e.g. "3x ~12 lines, 90% identical").
- **Decision**: `consolidated` | `tolerated` | `rejected` | `deferred`.
- **Rationale**: one line. For `consolidated`, name the new shared symbol and the
  before/after line delta. For `rejected`, name which rubric step killed it
  (break-even, coupling, config-bag, test-churn). For `deferred`, name the target
  (Session 10 / cross-module).
- **Commit**: short hash, for `consolidated` rows.

## Shared surface (grows bottom-up)

As each session confirms or creates a reusable helper, list it here so higher
sessions dedup against it instead of re-copying. Format: `symbol -- module -- what it does`.

| Symbol | Module | Purpose | Since |
|--------|--------|---------|-------|
| `Database.fetchOne(_:id:entity:)` | Persistence | Fetch a record by primary key or throw `PersistenceError.notFound`. Module-internal; use from any repository's `fetch(id:)` instead of re-rolling the guard/throw body. | S1 |
| `SQL.escapeFTSTerm` / `SQL.escapeLIKETerm` | Persistence | FTS5 MATCH prefix-token builder and LIKE operand escaper. Confirmed single-source (module-internal); do not re-implement inline. | S1 (pre-existing) |

## Findings

| ID | Session / scope | Location(s) | Kind | Copies / lines | Decision | Rationale | Commit |
|----|-----------------|-------------|------|----------------|----------|-----------|--------|
| _example_ | S0 / demo | `A.swift:10`, `B.swift:22` | near-duplicate-fn | 2x ~8 lines, 95% | tolerated | rule of three: only 2 copies, low churn risk | -- |
| S1-1 | S1 / Persistence repos | `ArtistRepository.fetch(id:)`, `AlbumRepository`, `LibraryRootRepository`, `PlaylistRepository`, `TrackRepository`, `EpisodeRepository`, `PodcastRepository` | near-duplicate-fn | 7x 8-9 lines, ~90% (only record type + entity string differ) | consolidated | Extracted `Database.fetchOne(_:id:entity:)` (generic over `FetchableRecord & TableRecord`). 3-param interface, no closures/config bag; call sites drop to one line; public `fetch(id:)` signatures + entity strings unchanged (no test churn). Net -17 lines. | `083de5a` |
| S1-2 | S1 / Persistence repos | `Repositories/*.swift` (~164 `database.read`/`write` closure sites) | boilerplate-wrapper | 20 repos, highly varied method sets | rejected | Seeded generic-`Repository<Record>` base: method sets diverge sharply (Track has 32 sites w/ FTS + custom queries; most repos 2-6). A base could only carry a thin, inconsistent slice while forcing a generic supertype on all -- config-bag/coupling trap. The one genuine win inside this surface is S1-1. | -- |
| S1-3 | S1 / Persistence repos | every `Repositories/*.swift` struct header | copy-paste-block | 16x 3 lines (`private let database` + `private let log` + `init`) | rejected | Sharing forces a common base type to remove 3 trivial, idiomatic lines; couples all repos to it for no behavior. Break-even + coupling. | -- |
| S1-4 | S1 / Persistence repos | `fetchAll()` in Album/Artist/LibraryRoot/Playlist/Track/Subsonic | near-duplicate-fn | ~6x 3 lines | tolerated | The `ORDER BY` clause is the payload and differs per repo; parameterizing it makes the call as long as the inline body (rubric step 3/4). | -- |
| S1-5 | S1 / Persistence repos | `AlbumRepository.count():156`, `TrackRepository.count():204` | near-duplicate-fn | 2x 2 lines | tolerated | Only two plain `fetchCount(db)` wrappers; the rest are filtered counts. Below rule of three. | -- |
| S1-6 | S1 / Persistence records | `Records/*.swift` `CodingKeys` | parallel-types | 15 records | tolerated | Each camelCase->snake_case map is a unique per-type schema, not structural duplication. A global `.convertFromSnakeCase` strategy would be a behavior change (out of scope) and risks columns that don't follow the rule. | -- |
| S1-7 | S1 / Persistence records | `Track.swift` `init(row:)` | boilerplate-wrapper | 1x | tolerated | Only Track hand-writes `init(row:)`; single occurrence, nothing to dedup. | -- |
| S1-8 | S1 / Persistence SQL | `Internal/SQL.swift` FTS builders | repeated-literal | 2 identical (`artistsFTSQuery`, `albumsFTSQuery`) + 1 variant (`tracksFTSQuery`) | tolerated | Only two are truly identical-shape; parameterizing the table name means interpolating SQL identifiers into the string and trading readable literal SQL. Rule of three not met for the clean pair. | -- |
| S1-9 | S1 / Persistence migrations | `Migrations/M0NN_*.swift` + `Migrator.make()` | copy-paste-block | 33x `register(in:)` shape | tolerated | Migration bodies are unique SQL and append-only/immutable; the `make()` list is an ordered manifest, clearest explicit. Seed forbids touching shipped bodies. | -- |
| S1-10 | S1 / Observability | `AppLogger.swift` trace/debug/info/notice/warning/error/fault | near-duplicate-fn | 7x 5 lines, ~90% | rejected | `os.Logger` has no behavior-preserving single `log(level:)` (its `OSLogType` has 5 cases, not 7; trace/notice/warning would remap). A sink-closure helper is ~break-even and adds a closure per call on the foundational logging API. Step 4: prefer the duplication. | -- |

<!--
Append rows below per session. Keep the example row at the top as the format
reference. Do not delete rows once written.
-->

## Running totals

Update at the end of each session (Session 10 finalizes):

- Lines removed (net): _17_
- Consolidated: _1_  ·  Tolerated: _6_  ·  Rejected: _3_  ·  Deferred: _0_
- New shared helpers introduced: _1_ (`Database.fetchOne(_:id:entity:)`)
