# Session 1: Observability + Persistence

> Read [README.md](README.md) first (method, rubric, guardrails). This file is
> scope + starting points only.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Modules/Observability/Sources` | 9 | ~610 | The bottom of the DAG. Small; calibrate the method here. |
| `Modules/Persistence/Sources` | 81 | ~7.5k | GRDB records, repositories, migrations, observation. |

Prereq: none -- this is the floor. Gate: `make test-observability`, `make test-persistence`.

## Start here (seeded candidates)

- **Repository CRUD boilerplate.** ~164 `self.database.read` / `self.database.write`
  closure sites across `Repositories/*.swift`. Many repos repeat
  `insert`/`fetch(id:)`/`fetchAll()`/`count()` with only the record type
  changing. Normalized-diff a few repos against each other; consider whether a
  generic `Repository<Record>` base or small fetch helpers pay off -- **or**
  whether this is idiomatic GRDB that reads fine as-is (very possible; measure
  before touching, this is a classic over-abstraction trap).
- **Record boilerplate.** `Records/*.swift` (`Track`, `Album`, `Artist`, ...)
  repeat `CodingKeys` and `init(row:)`. Check whether GRDB's derivation removes
  any hand-written repetition without behavior change.
- **Migration registration.** `Migrations/M0NN_*.swift` + `Migrator.swift` --
  look for a repeated per-migration shape that a helper could carry (but
  migrations are append-only and immutable once shipped; touch only the
  registration wiring, never a shipped migration body).
- **Raw-SQL helpers.** `Internal/SQL.swift` -- confirm FTS/LIKE builders are not
  re-implemented inline in repos that bypass it.
- **Observability.** `AppLogger`, redaction, MetricKit listener -- small surface;
  a quick normalized-diff of the log-category plumbing is enough.

## Workflow (per README)

1. Inventory the repository + record surface.
2. Cluster with the normalized-diff.
3. Walk the rubric per cluster -- expect many "tolerated" (idiomatic GRDB) and a
   few real "consolidated".
4. Apply: pure-move commits first if splitting, then dedup.
5. Verify gates.
6. Log every cluster in the ledger.
7. Record any new shared helper in the ledger's "shared surface" table -- this is
   the module every higher session can dedup against, so be thorough here.

## Exit criteria

- Every repository and record triaged; ledger rows for all clusters.
- `make test-observability`, `make test-persistence`, `make lint`, `make build`
  green.
- Shared-surface table updated with anything reusable Persistence now exposes.
