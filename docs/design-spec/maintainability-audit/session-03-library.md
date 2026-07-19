# Session 3: Library

> Read [README.md](README.md) first. Scope + starting points only.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Modules/Library/Sources` | 64 | ~9.6k | Folder scanner, FSEvents watcher, conflict resolver, cover-art cache, importer. |

Prereq: Sessions 1 to 2 (dedup against Persistence + Metadata surfaces). Gate:
`make test-library`.

## Start here (seeded candidates)

- **Scanner / importer paths.** The full-scan, incremental-scan, and add-files
  paths often share track-construction and tag-mapping. Normalized-diff the
  import entry points for a common core that variants call with different
  sources.
- **Tag -> record mapping.** Building `Track`/`Album`/`Artist` records from tags
  likely recurs across scan, add-files, and metadata-edit reconciliation. A
  single mapping function is a strong candidate if 3+ copies exist.
- **FSEvents / watcher plumbing.** Debounce + coalesce + dispatch patterns --
  check for copies between the folder watcher and any other file-watching code.
- **Cover-art cache.** Hashing + path derivation + write -- confirm there is one
  path, not several. Note it in the shared surface (`UI` and others read cover
  paths; a duplicated hash scheme would be a cross-module bug risk).
- **Conflict resolution.** Look for repeated "compare old vs new field, decide"
  ladders that a table-driven helper could compress.

## Notes

Library is large and central; budget the full session for it and do not spill
into Session 4. If a cluster is big and risky, prefer **logging it** with a
concrete plan over a rushed extraction.

## Exit criteria

- Library fully triaged; ledger rows for all clusters.
- Cover-art path/hash scheme confirmed single-source; recorded in shared surface.
- `make test-library`, `make lint`, `make build` green.
