# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Scrobble` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

Submitting "now playing" and play events to scrobble services, resilient to being offline.

- `Providers/` implements the `ScrobbleProvider` protocol for Last.fm, ListenBrainz, Rocksky, and Subsonic. `LastFmSignature.swift` builds the signed API params; `Auth/` handles the web-auth token flow.
- `Queue/` is the durable spine: `ScrobbleQueueRepository` persists pending submissions (with per-provider status) and `ScrobbleQueueWorker` is the per-provider drain loop that wakes on enqueue, reachability, launch, and retry backoff.
- `ScrobbleService.swift` ties providers to the queue; `ScrobbleRules.swift` decides what counts as a scrobble; `PlayEvent.swift` is the unit of work.

## Things easy to get wrong

- **Submission status is a free-text TEXT column** with string values: `pending`, `sent`, `ignored`, `failed`, and `sent_unconfirmed`. The `sent_unconfirmed` sentinel exists so that a provider that already accepted a scrobble is never re-sent if the confirming DB write fails. Any new status must be threaded through `fetchPending`, the `markSucceeded` rollup, `reviveDead`, both `submittedToday` stats queries, and the UI badge.
- **`queryRecent` LEFT JOINs `tracks`** and COALESCEs onto the `payload_*` columns, because Subsonic-sourced rows have `track_id IS NULL` and carry their metadata in the queue payload. An INNER JOIN silently drops them.
- **The worker's `observeStats`/`stats` take an injectable `now`** clock so the "submitted today" boundary is testable; do not hard-code `Date()` inside the observation closure. The reachability subscription `Task` is stored and cancelled in `stop()`.
- **Tests must not hit the network.** Stub the HTTP client; provider tests assert request shape (signed params, POST body), not live calls.

## Testing

Run `make test-scrobble` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/Scrobble`, or `make test-coverage`), run `make test-scrobble` last so the full module suite is the final gate before the commit.
