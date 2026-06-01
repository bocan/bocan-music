# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Observability` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

The logging and diagnostics floor of the app. It is the **root of the module DAG**: every other module depends on it and it depends on nothing of ours, so it must stay free of any `import` from a sibling module (or you create a cycle).

- `AppLogger` (`AppLogger.swift`) is the single logging facade. Categories are an enum in `LogCategory.swift`: `app`, `audio`, `library`, `metadata`, `persistence`, `ui`, `network`, `playback`, `cast`, `scrobble`, `subsonic`.
- `LogStore` (`LogStore.swift`) is the process-wide in-memory ring buffer (capacity 5,000) that `AppLogger` tees into. After building the formatted, redacted message string, each `AppLogger` level method calls `LogStore.shared.record(level:category:message:)`. `LogLevel.swift` and `LogEntry.swift` are the supporting value types. `LogStore` must never call `AppLogger` (no recursion).
- `Redaction.swift` scrubs sensitive values automatically. `Observability.sensitiveKeys` (apiKey/token/sessionKey/password/authorization, etc.) are redacted from log metadata, and `scrubURLQueryParams` strips secret query params from URLs.
- `Telemetry.swift` / `MetricKitListener.swift` receive `MXDiagnosticPayload`s and persist them. The listener only starts once the user has granted diagnostics consent.

## Conventions that originate here

- **All logging goes through `AppLogger`.** No `print`, no raw `os_log`, anywhere in the codebase. The standard shape is `log.debug("op.start", [...])` / `log.error("op.failed", ["error": String(reflecting: err)])`.
- When adding a redaction, prefer extending `sensitiveKeys`/`sensitiveQueryParams` over scrubbing at call sites. `scrubURLQueryParams` uses manual string splitting on `?`/`&`/`=` (not `URLComponents`, which percent-encodes the `<redacted>` placeholder and breaks the contract).

## Testing

Run `make test-observability` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/Observability`, or the cross-cutting `make test-coverage`), run `make test-observability` last so the full module suite is the final gate before the commit.
