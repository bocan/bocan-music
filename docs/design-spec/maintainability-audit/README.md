# Phase 24: Maintainability Audit

A cross-cutting, bottom-up sweep of the whole codebase for **duplication that
should be parameterized or shared**. Unlike phases 0 to 23, this ships no
features. It reads existing code, finds functions and blocks that are *mostly*
the same, and compresses the ones where compression is a genuine win, leaving a
recorded decision for the ones where it isn't.

This directory is the charter (this file), a running [findings ledger](findings-ledger.md),
and ten session files sized to roughly one working session each. Read this file
once; each session file is deliberately thin and leans on the method here.

> This is an audit, not an engineering phase, so the format is different from
> the `phase-NN-*.md` specs. There is no "acceptance criteria" for a feature.
> The deliverable is: a smaller, less-repetitive codebase where it helped, and a
> ledger entry for every candidate considered, including the ones left alone.

## Why this exists

An AI (or a team) building quickly accretes near-duplicate code: two functions
that do almost the same thing where one parameterized function would do; a block
copy-pasted into three views; parallel types that drifted from a common shape.
It rarely breaks anything at runtime. It taxes *maintainability*: when a
behavior must change, it now lives in N places, and the one that gets missed
becomes a bug.

The Phase 23 close-out already found and fixed several instances (four copied
segmented pickers, three copied `writePNG` helpers, a duplicated list row). It
also found one where consolidation was the *wrong* call (a generic that folded
two views into a 14-field config bag). Both outcomes are the point: this phase
systematizes the search **and** the judgment.

## Non-goals

- **No behavior changes.** Every commit is behavior-preserving. If a refactor
  would change what the app does, it is out of scope; file it separately.
- **No new features, no dependency bumps, no schema changes.**
- **No performance work** unless a duplication removal makes it free.
- **Not a style pass.** Formatting, naming, and comment cleanups are not the
  target; `swiftformat`/`swiftlint` already own those. The target is *structural*
  duplication.
- **No test deletion.** Tests may be consolidated (see the `writePNG` example),
  never dropped for coverage's sake.
- **Do not chase perfection.** The rule of three (below) is the bar. Two copies
  are allowed to live.

## Why bottom-up

The module DAG (from the root `CLAUDE.md`):

```
Observability -> Persistence -> AudioEngine, Metadata, Library, Playback,
  Scrobble, Subsonic, Acoustics, SyncServer, Podcasts -> UI -> App
```

Audit lowest-first for two reasons:

1. **Shared helpers belong low.** If two UI views and one Library file all format
   a duration, the shared helper wants to live at or below the lowest common
   module. You cannot see that a helper is duplicated *across* layers until the
   lower layer is already mapped. Each session records its module's reusable
   surface in the ledger so higher sessions can dedup against it.
2. **Low modules are smaller and more mechanical**, so the method is easy to
   calibrate there before the 48k-line `UI` module.

Cross-module duplication (the same helper in three modules) is **noted** as it is
found but **resolved in the final session** (Session 10), once every module's
surface is in the ledger.

## The duplication taxonomy: what to look for

| Kind | Smell | Typical fix |
|------|-------|-------------|
| **Near-duplicate functions** | two funcs differ only in a constant, a type, or one branch | one function with a parameter |
| **Copy-paste blocks** | the same 10+ lines inline in N places | extract a function or a small view/type |
| **Parallel types** | two structs/enums with the same shape and drift | a shared base, or a generic, *if the interface stays small* |
| **Boilerplate wrappers** | every call re-does the same setup/teardown | a higher-order helper (`withThing { ... }`) |
| **Repeated literals / SQL / format strings** | the same query shape or format string many times | a builder or a named constant |
| **Duplicated test scaffolding** | each test file rebuilds the same fixture/stub | one shared test helper |

## The decision rubric: consolidate or leave?

This is the heart of the phase. Finding duplication is easy; deciding what to do
about it is the skill. For every cluster of similar code, walk this in order.

**Step 1 - Count and measure.** How many copies? How many lines each? Use the
normalized-diff (see toolkit) to see the *true* overlap, not the apparent one.

**Step 2 - Apply the rule of three.** Two copies: usually leave them, log as
"tolerated". Three or more near-identical copies: a real candidate; proceed.
(Exception: two copies of a genuinely tricky algorithm that *must* stay in
lockstep -- e.g. an encoder and its decoder -- can be worth sharing at two.)

**Step 3 - Draft the extraction and measure the delta.** Actually write it (or
sketch it). Then compare:
- **Lines before vs after**, counting the new shared code. A real win drops the
  total meaningfully. Break-even is a red flag.
- **Interface size of the shared thing.** A helper with 1 to 3 parameters is
  cheap. A "shared" thing that needs a 10+ field config object, a fistful of
  closures, or heavy generics has just moved the complexity, not removed it.
- **Call-site length.** If each caller must pass so much configuration that the
  call is as long as the original inline code, you gained nothing.

**Step 4 - The "cleverer, not better" test.** If the consolidated version is
break-even on lines *and* adds indirection, generics, or a config bag: **prefer
the duplication.** Cleverness is not the goal; a maintainer understanding the
code in one place is.

**Step 5 - The coupling test.** Does the shared abstraction force two things that
are independent-by-coincidence to change together forever? Two views that look
alike today but model different concepts (a Genre listing and a Composer
listing) may be twins by accident. Sharing the *config-free* pieces (a row view,
a pure sort function) is safe; fusing them into one engine couples them. Prefer
sharing the leaves, not the trunk.

**Step 6 - The test-churn signal.** If applying the extraction forces you to
rewrite source-convention tests because *tested behavior moved into the shared
code*, pause. Relocating behavior is a bigger change than deduping a leaf and
often signals over-consolidation. Deduping a genuinely config-free helper should
require **no** behavior-test changes (tests may need to point at the new symbol,
which is fine; they should not need to move an assertion from view A into a
shared engine).

**Outcome for every cluster** -- record one of:
- **Consolidated** -- extracted; commit hash in the ledger.
- **Tolerated** -- 2 copies or below the bar; left as is, one-line reason.
- **Rejected** -- consolidation tried and judged worse; left as is, with the
  reason (break-even, coupling, config-bag, etc.). Recording rejections stops a
  future audit from re-litigating them.
- **Deferred** -- real cross-module candidate; logged for Session 10.

## Guardrails

- **Behavior-preserving only.** If in doubt whether a change alters behavior,
  it does; stop and log it as out-of-scope.
- **Gates stay green every commit.** `make format`, `make lint`, `make build`,
  and the relevant `make test-*` (plus `make test-coverage`, and
  `make test-ui` / `make pseudolocale` when `UI`/the catalog is touched). A
  refactor that needs a gate turned off is not a refactor.
- **One logical change per commit.** A pure move is its own commit (so
  `git blame` survives); the consolidation that follows is another. Conventional
  Commits, `refactor(<module>): ...` or `test(<module>): ...`.
- **Don't fight the file-length ceiling with the audit.** Extracting to satisfy
  the 500-line lint rule is fine and welcome, but the goal is dedup, not moving
  lines around to pass a metric.
- **Respect the module DAG.** A shared helper goes at or below the lowest module
  that uses it; never introduce an upward import to share code.
- **Localization stays intact.** Shared UI helpers still route copy through
  `L10n`; running `make pseudolocale` after catalog-affecting changes is
  required (usually there are none in a pure dedup).

## Per-session workflow

Each session covers one scope (a module or a cluster). Run this loop:

1. **Inventory.** List the function/type surface in scope. `grep`, the file
   tree, and the toolkit below. Note anything the ledger already marks as shared
   from lower sessions.
2. **Cluster.** Group by similarity. The normalized-diff trick surfaces
   near-twins fast.
3. **Decide.** Walk the rubric for each cluster. Most clusters end at "tolerated"
   or "rejected" -- that is normal and healthy.
4. **Apply.** For "consolidated" clusters: pure-move commit first if a file split
   is involved, then the dedup commit. Keep each small.
5. **Verify.** Gates green after each commit.
6. **Log.** Append every considered cluster to the ledger (all four outcomes),
   with locations and the one-line rationale.
7. **Record reusable surface.** In the ledger's "shared surface" section, note
   any helper this session created or confirmed, so higher sessions dedup
   against it.

Sessions are independent and resumable: the ledger is the memory. A session is
done when its scope is fully triaged and every cluster has a ledger row.

## Candidate-finding toolkit

Concrete commands. None of these decide anything; they surface candidates for
the rubric.

- **Normalized diff (find near-twins):** strip the naming that differs, then
  diff. This is how Phase 23 found that two 187-line views were 85% identical:
  ```sh
  sed -E 's/[Gg]enre/X/g; s/[Cc]omposer/X/g' A.swift > /tmp/a
  sed -E 's/[Gg]enre/X/g; s/[Cc]omposer/X/g' B.swift > /tmp/b
  diff /tmp/a /tmp/b        # few diff lines => near-duplicate
  ```
- **Repeated call shapes:** `grep -rc "self.database.read" Modules/.../Repositories/*.swift`
  (Session 1 already shows ~164 read/write closure sites -- a boilerplate
  candidate).
- **Scattered formatting:** `grep -rln "DateComponentsFormatter|ByteCountFormatter|%02d:%02d" Modules/*/Sources`
  (~13 files today -- a cross-module shared-formatter candidate for Session 10).
- **Duplicated test scaffolding:** `grep -rln "URLProtocol|Mock.*Client|writePNG" Modules/*/Tests`.
- **Line-delta measurement:** before/after `wc -l`, counting the new shared file.
- **`/simplify`** -- applies reuse/simplification fixes to the working diff; good
  for a first mechanical pass on a scope.
- **`/code-review`** -- reports (does not apply) reuse/duplication findings; good
  for an independent read of a scope before you commit.

## Findings ledger

The durable artifact. One row per considered cluster, appended per session. See
[findings-ledger.md](findings-ledger.md) for the format and the running table.
Every row -- consolidated, tolerated, rejected, deferred -- stays, so the audit
is auditable and never re-litigated.

## Session index

Bottom-up. Each row is ~one session; the large ones may split.

| # | Scope | Approx size | File |
|---|-------|-------------|------|
| 1 | Observability + Persistence | ~8.1k lines | [session-01-observability-persistence.md](session-01-observability-persistence.md) |
| 2 | AudioEngine + Metadata + Acoustics | ~7.5k | [session-02-audio-metadata-acoustics.md](session-02-audio-metadata-acoustics.md) |
| 3 | Library | ~9.6k | [session-03-library.md](session-03-library.md) |
| 4 | Playback + Scrobble | ~6.8k | [session-04-playback-scrobble.md](session-04-playback-scrobble.md) |
| 5 | Subsonic + SyncServer + Podcasts | ~9.2k | [session-05-subsonic-syncserver-podcasts.md](session-05-subsonic-syncserver-podcasts.md) |
| 6 | UI spine (ViewModels, AppRoot, Common, Theme, Utility, Accessibility, Components) | ~10k | [session-06-ui-spine.md](session-06-ui-spine.md) |
| 7 | UI Browse (tracks/albums/artists tables, Subsonic browse) | ~13k | [session-07-ui-browse.md](session-07-ui-browse.md) |
| 8 | UI creation + config (Playlists, Settings, MetadataEditor, Import, Tools) | ~11.8k | [session-08-ui-playlists-settings.md](session-08-ui-playlists-settings.md) |
| 9 | UI media surfaces (Visualizers, DSP, Lyrics, MiniPlayer, Transport, Fingerprint, Console, Scrobble) | ~12.9k | [session-09-ui-media-surfaces.md](session-09-ui-media-surfaces.md) |
| 10 | App + cross-module sweep + close-out | ~3.5k + synthesis | [session-10-app-cross-module.md](session-10-app-cross-module.md) |

Estimated at ten sessions, ~1.5 to 2 weeks of focused work. Sessions 6 to 9
(the `UI` module) are the bulk; do not let them sprawl -- one scope per session,
triage fully, log, stop.

## Definition of done

- Every session file's scope is fully triaged; every cluster has a ledger row.
- Cross-module candidates raised in Sessions 1 to 9 are resolved or explicitly
  deferred-with-reason in Session 10.
- All gates green on the final state.
- Session 10 writes a one-page close-out: total lines removed, count of
  consolidated vs tolerated vs rejected, and the shared helpers now available so
  the next feature reuses instead of re-copying.
