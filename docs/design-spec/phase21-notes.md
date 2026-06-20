# Phase 21 Notes

> Status: the FeedKit upgrade path described below has been scoped into
> `phase21-11-feedkit-upgrade.md` (the 9.1.2 to 10.4.0 upgrade) and
> `phase21-12-podcast-features.md` (new podcast functionality the upgrade
> unlocks). This file remains as the original problem statement.

## FeedKit version debt

Phase 21-2 locked in FeedKit **9.1.2**, which is approximately six years old and predates Swift 6 concurrency. The library's types (`RSSFeed`, `AtomFeed`, etc.) are plain classes with no `Sendable` conformances, which is why `FeedParser.swift` carries a `@preconcurrency import FeedKit` workaround and a comment explaining that all FeedKit types must be created and consumed synchronously without crossing an actor boundary.

The current version of FeedKit (10.x as of mid-2025) may have a different API surface, better Swift 6 support, or different packaging. The 9.1.2 pin should be treated as temporary scaffolding.

**After all other phase 21 slices are complete**, a dedicated spec file should be written to scope out the FeedKit upgrade path. That spec should cover:

- Confirming the latest stable release and its minimum platform requirements.
- Auditing API diffs: field naming (the `iTunes`-prefix convention changed between major versions), `Feed` enum cases, `ParserError` type, and any new namespace support (e.g. the `podcast:` namespace for chapters, transcripts, funding).
- Deciding whether to stay on FeedKit or replace it with a more actively maintained alternative (e.g. a hand-rolled `XMLParser` pipeline, which would also eliminate the third-party dependency entirely).
- Updating `FeedParser.swift` to remove the `@preconcurrency` workaround and any Sendable-boundary comments once the upstream types are properly annotated.
- Re-running the full test suite and snapshot-testing any behavioural differences in episode ordering, duration parsing, or category extraction.

A suggested filename for that future spec: `phase21-11-feedkit-upgrade.md`.

## Process note

The FeedKit version mismatch was a process gap: the spec was written without checking the current library version against what was actually resolvable via SPM. Using context7 (or any live documentation tool) during spec authoring to verify version availability and API surface would have caught this before implementation started. Worth making that a standard step in future spec writing for any slice that introduces a new third-party dependency.
