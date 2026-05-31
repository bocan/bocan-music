# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Persistence` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

The SQLite layer, built on **GRDB 7**. Everything above persistence talks to it through typed repositories, never raw SQL strings scattered in feature code.

- `Database.swift` is the entry point: an actor-ish wrapper exposing `read` / `write` / `observe`. WAL mode is enabled in `configure`. `db.write` wraps its closure in a transaction, so a throw rolls the whole thing back (all-or-nothing).
- `Records/` are the row structs (`Track`, `Album`, `Artist`, `Playlist`, ...) conforming to GRDB's `FetchableRecord`/`PersistableRecord`. `Repositories/` are the typed query API on top.
- `Migrations/` holds **numbered, append-only** migrations `M001_…` through `M0NN_…`, registered in `Migrator.swift`. `Internal/SQL.swift` holds shared raw-SQL helpers (FTS5 MATCH builders, LIKE escaping).
- `Observation/` exposes `ValueObservation` streams so the UI updates reactively. `Backup/` handles database export/restore.

## Things easy to get wrong

- **Migrations are immutable once shipped.** Never edit a migration that has run on a real database; add a new `M0NN_*.swift` and register it in `Migrator.make()`. The migration count and `schemaVersion` are asserted in tests, so bumping the schema means updating `MigrationTests`.
- **Search input must be escaped.** FTS5 MATCH terms go through `SQL.escapeFTSTerm` (double-quotes doubled, tokens wrapped as prefix queries); LIKE operands go through `SQL.escapeLIKETerm` plus `ESCAPE '\'` in the SQL (note the Swift literal needs `ESCAPE '\\'`). A bare `%`/`_` otherwise acts as a wildcard.
- **A swallowed pragma is a real bug.** WAL/journal pragmas are set in `configure`; failures are logged (not `try?`-dropped) because losing WAL silently breaks `ValueObservation` snapshot semantics.
- Tests open `Database(location: .inMemory)`; never touch the on-disk app database from a test.

## Testing

Run `make test-persistence` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/Persistence`, or `make test-coverage`), run `make test-persistence` last so the full module suite is the final gate before the commit.
