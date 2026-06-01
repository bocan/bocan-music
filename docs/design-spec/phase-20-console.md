# Phase 20: In-App Log Console

> Prerequisites: Phases 0-19 complete. `AppLogger` (`Observability`) is the
> single logging facade; every module logs through it. `DiagnosticsSettingsView`
> exists in `Modules/UI/Sources/UI/Settings/`. Scene / window / menu wiring
> lives in `App/`. Deployment target is macOS 15+ (so `Synchronization.Mutex`
> is available).
>
> Read `docs/design-spec/_standards.md` first.

## Where this fits: the brief, reviewed

The user currently watches the app's logs from a terminal with:

```
log stream --predicate 'subsystem == "io.cloudcauldron.bocan"' --level debug
```

They asked for an in-app equivalent: a window that shows all of Bocan's logs
since launch and can tail them live, so they can investigate an issue or just
confirm things are healthy without leaving the app.

This phase delivers exactly that, with two deliberate decisions called out up
front because they shape everything below:

1. **We do not read the unified log via `OSLogStore`.** `OSLogStore` only
   returns *persisted* entries, which is `notice` and above. `debug` and `info`
   are not written to the persistent store, so an `OSLogStore`-backed viewer
   would silently drop almost all of Bocan's traffic (the codebase logs heavily
   at `debug`: `op.start` / `op.end`). The terminal command works precisely
   because live streaming elevates capture; an in-app reader cannot replicate
   that from the store.

2. **We add a small in-process ring buffer inside `AppLogger`.** Because every
   log line in the codebase funnels through the one facade, we tee each call
   into a bounded, lock-guarded buffer in addition to emitting to `os.Logger`.
   A SwiftUI window backfills from the buffer and tails new entries. This
   captures 100% of what the app logs (including `debug` / `info`), satisfies
   "everything since launch" for free, needs no entitlements, and is trivial
   under the sandbox.

If you disagree with either decision, the rest of the spec still mostly holds:
the UI is decoupled from the capture mechanism behind `LogStore`, so a future
`OSLogStore` source could be slotted in without rewriting the window.

## Goal

A "Log Console" window, openable from the Help menu and from Settings ->
Diagnostics, that:

- Shows every log line emitted since the process started (up to a bounded
  history), oldest at top.
- Tails new lines live, with an auto-scroll "tail mode" toggle.
- Filters by minimum level and by category, and free-text searches the message.
- Lets the user pause ingestion, clear the view, copy lines, and export the
  visible log to a `.log` file.

All of this reads from an in-memory buffer that is already redacted (the
existing `Redaction.sanitize` runs before the stored string exists), so no
secrets enter the buffer or the export.

## Non-goals

- Reading the macOS unified log (`OSLogStore`). See decision 1 above.
- Persisting the log buffer to disk across launches. The buffer is
  memory-only; "since it started" means since this launch. Export is a manual,
  point-in-time action.
- Changing what gets logged, the log categories, or the redaction rules.
- A remote / networked log sink, log shipping, or crash upload. MetricKit
  crash reporting (Phase 16 / `DiagnosticsSettingsView`) is unchanged and
  separate.
- Structured field inspection (expandable key/value trees). We store the same
  flat, formatted string that goes to `os.Logger`. A future phase can enrich
  this if wanted (see Handoff).

## Outcome shape

```
Modules/Observability/Sources/Observability/
├── AppLogger.swift          # tee each level into LogStore (small change)
├── LogLevel.swift           # NEW: level enum, Comparable, display metadata
├── LogEntry.swift           # NEW: one captured line (Sendable value type)
└── LogStore.swift           # NEW: bounded ring buffer + live broadcast

Modules/Observability/Tests/ObservabilityTests/
├── LogStoreTests.swift      # NEW
├── LogEntryTests.swift      # NEW
└── AppLoggerCaptureTests.swift  # NEW

Modules/UI/Sources/UI/Console/
├── LogConsoleView.swift             # NEW: the window's content view
├── LogConsoleRow.swift              # NEW: one row (timestamp/level/category/msg)
└── ViewModels/
    └── LogConsoleViewModel.swift    # NEW: backfill + tail + filter + export

Modules/UI/Tests/UITests/ViewModelTests/
└── LogConsoleViewModelTests.swift   # NEW
Modules/UI/Tests/UITests/
└── LogConsoleViewSnapshotTests.swift # NEW (runs under make test-ui only)

App/Sources/...
├── BocanApp.swift           # register the Window scene + window id
└── BocanCommands.swift      # Help-menu "Log Console" command + shortcut

Modules/UI/Sources/UI/Settings/
└── DiagnosticsSettingsView.swift  # "Open Log Console" button + capture toggle
```

## User-visible surface

### The window

A standalone, resizable window (id `"log-console"`), default size ~900x520,
minimum ~600x320. Not a sheet, so the user can keep it open beside the main
window while they reproduce an issue.

```
┌─ Log Console ─────────────────────────────────────────────────────────┐
│ [Level: Debug ▾]  [Categories: All ▾]  [Search… 🔍________]            │
│ [⏸ Pause] [Clear] [Copy] [Export…]              Tail ▣   4,812 lines   │
├───────────────────────────────────────────────────────────────────────┤
│ 12:04:18.221  DEBUG   audio      decoder.start [format=FLAC sampleRate… │
│ 12:04:18.244  DEBUG   audio      decoder.end [ms=23]                    │
│ 12:04:18.502  INFO    playback   playback.track [id=4471 title=…]       │
│ 12:04:19.010  WARNING subsonic   capabilities.persist.read.failed [err… │
│ 12:04:21.778  ERROR   ui         transport.next.failed [error=…]        │
│ …                                                                       │
│                                                       [ Jump to latest ⤓]│
└───────────────────────────────────────────────────────────────────────┘
```

Controls:

- **Level** picker: minimum level to show (Trace, Debug, Info, Notice, Warning,
  Error, Fault). Default Debug, matching the terminal command.
- **Categories** menu: multi-select over the `LogCategory` cases, plus
  "All". Default All.
- **Search** field: case-insensitive substring match over the rendered message.
- **Pause** toggle: stops new lines flowing into the view. The buffer keeps
  filling underneath, so unpausing backfills what was missed (up to capacity).
- **Clear**: clears the *view*. A secondary "Clear Buffer" item (in an
  overflow menu) empties the underlying `LogStore` too.
- **Copy**: copies the currently visible (filtered) lines to the clipboard.
- **Export…**: save panel writes the visible lines to a `.log` text file.
- **Tail** toggle: when on, the list auto-scrolls to the newest line as lines
  arrive. Scrolling up, or pressing Pause, turns Tail off. A **Jump to latest**
  affordance re-engages it.
- **Line count** read-out: visible-count, and a subtle note when the buffer is
  at capacity (oldest lines being dropped).

Each row: monospaced. `HH:mm:ss.SSS` timestamp, a colored level badge, the
category, then the message. Rows are `textSelection(.enabled)`. Level color:
Trace/Debug secondary-grey, Info primary, Notice blue, Warning amber, Error/
Fault red. Respect `differentiateWithoutColor` by also showing the level text
(never color alone).

### Discoverability

- **Help menu** -> "Log Console" (suggested shortcut `Shift-Cmd-L`; the
  implementer must confirm it does not collide in `BocanCommands`, since `Cmd-L`
  is already Love). Opens or focuses the window.
- **Settings -> Diagnostics**: an "Open Log Console" button, plus a "Capture
  in-app logs" toggle (default on) and the history-size read-out.

## Definitions and contracts

### LogLevel

`Modules/Observability/Sources/Observability/LogLevel.swift`

```swift
/// Severity of a captured log line, ordered low -> high for min-level filters.
public enum LogLevel: Int, Sendable, CaseIterable, Comparable, Codable {
    case trace = 0
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Upper-case label shown in the console ("DEBUG", "WARNING", ...).
    public var label: String { ... }
}
```

### LogEntry

`Modules/Observability/Sources/Observability/LogEntry.swift`

```swift
/// One captured log line. The `message` is already formatted and redacted
/// (it is the exact string handed to `os.Logger`), so storing it is safe.
public struct LogEntry: Identifiable, Sendable, Hashable {
    /// Monotonic sequence number assigned by `LogStore`. Stable SwiftUI identity,
    /// total ordering, and cheap dedup across backfill + live stream.
    public let id: UInt64
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
}
```

Use the sequence number, not a `UUID`, for `id`: it gives a total order, makes
the "did I already show this from the backfill" check trivial, and keeps
`ForEach` identity stable.

### LogStore

`Modules/Observability/Sources/Observability/LogStore.swift`

A process-wide, bounded ring buffer plus a live broadcast to N subscribers.

```swift
public final class LogStore: Sendable {
    /// App-wide singleton the `AppLogger` facade tees into.
    public static let shared = LogStore(capacity: 5_000)

    public init(capacity: Int)

    /// On by default. When false, `record` is a cheap no-op.
    public var isCaptureEnabled: Bool { get set }

    public var capacity: Int { get }

    /// Append a line. Cheap, synchronous, lock-guarded, never blocks on I/O.
    /// Called from any thread / actor by `AppLogger`.
    public func record(level: LogLevel, category: LogCategory, message: String)

    /// Current contents, oldest first.
    public func snapshot() -> [LogEntry]

    /// Empty the buffer (does not affect already-displayed view copies).
    public func clear()

    /// Atomically return the current snapshot AND register a live subscriber,
    /// so no line is missed or duplicated in the gap between the two. The
    /// stream yields only lines recorded after the snapshot. The subscriber is
    /// removed when the stream's task is cancelled / terminated.
    public func backfillAndSubscribe() -> (backfill: [LogEntry], live: AsyncStream<LogEntry>)
}
```

Concurrency model:

- Internal state (ring array, head, count, `nextID`, subscriber continuations)
  lives behind a single `Mutex` from `import Synchronization` (macOS 15+).
  `OSAllocatedUnfairLock` is an acceptable fallback if `Mutex` proves awkward,
  but prefer `Mutex`.
- `record` does: bail if disabled; take the lock; assign `id = nextID += 1`;
  push into the ring (evicting oldest when full); snapshot the live
  continuations into a local array; release the lock; **yield to each
  continuation outside the lock**. Yielding inside the lock risks re-entrancy
  and deadlock; yielding outside is the rule.
- `backfillAndSubscribe` takes the lock, copies the ring, builds an
  `AsyncStream` whose continuation is stored in the subscribers map keyed by a
  token, sets `onTermination` to remove that token (re-taking the lock), and
  returns both. All under, or coordinated by, the one lock.
- `record` must not call `AppLogger` (no recursion) and must not allocate
  unboundedly. The `message` string is already built by the caller.

### AppLogger hook

`Modules/Observability/Sources/Observability/AppLogger.swift`

Two small changes:

1. Store the category so captured entries can carry it:

```swift
public struct AppLogger: Sendable {
    private let logger: os.Logger
    private let category: LogCategory   // NEW

    public init(category: LogCategory, subsystem: String = "io.cloudcauldron.bocan") {
        self.category = category         // NEW
        self.logger = os.Logger(subsystem: subsystem, category: category.rawValue)
    }
    ...
}
```

2. Tee each level into the store after building `msg` (reuse the existing
   string; do not format twice):

```swift
public func debug(_ message: @autoclosure @Sendable () -> String, _ fields: [String: Any] = [:]) {
    let msg = self.format(message(), fields)
    self.logger.debug("\(msg, privacy: .public)")
    LogStore.shared.record(level: .debug, category: self.category, message: msg)
}
```

Apply the identical pattern to `trace` (-> `.trace`), `info`, `notice`,
`warning`, `error`, `fault`. `msg` is already the redacted, k=v-suffixed string,
so the store inherits redaction with zero extra work.

### Console view model

`Modules/UI/Sources/UI/Console/ViewModels/LogConsoleViewModel.swift`

```swift
@MainActor
@Observable
public final class LogConsoleViewModel {
    // Inputs (bound to the toolbar)
    public var minimumLevel: LogLevel = .debug
    public var selectedCategories: Set<LogCategory> = []   // empty == All
    public var searchText: String = ""
    public var isPaused: Bool = false
    public var isTailing: Bool = true

    // Outputs
    public private(set) var visible: [LogEntry] = []
    public private(set) var totalCount: Int = 0
    public private(set) var isAtCapacity: Bool = false

    public init(store: LogStore = .shared)

    public func start()      // backfillAndSubscribe + begin batched flush
    public func stop()       // cancel subscription + flush timer
    public func clearView()
    public func clearBuffer()
    public func exportText() -> String      // visible lines, one per row
    public func copyText() -> String
}
```

Key behaviours:

- `start()` calls `store.backfillAndSubscribe()`, seeds an internal capped
  mirror (`allEntries`, cap = `store.capacity`) with the backfill, then consumes
  the live stream into a pending queue.
- **Batched flush, not per-line:** a `~10 Hz` flush (matching the codebase's
  existing coalescing pattern, e.g. scan-progress at 4 Hz) drains the pending
  queue into `allEntries` and recomputes `visible`. This is essential. Bocan
  can emit hundreds of `debug` lines per second during a scan or playback
  start; appending per-line on the main actor would melt it (the same hazard
  the scan coalescing and menu-bar `let` view models guard against). The flush
  is a no-op while `isPaused` (entries keep accumulating in the mirror; only
  the view stops updating).
- `visible` = `allEntries` filtered by `minimumLevel`, `selectedCategories`
  (empty set means all), and a case-insensitive `searchText` substring on
  `message`. Recompute on flush and when any filter input changes.
- Tail engages auto-scroll in the view; `isPaused = true` forces
  `isTailing = false`.
- `stop()` cancels the stream task and the flush timer; call it from the view's
  `onDisappear` so a closed window does not keep draining.

### Module boundaries

- `LogStore`, `LogEntry`, `LogLevel` live in `Observability` (DAG root, imports
  nothing of ours). `Observability` may import `Foundation`, `os`,
  `Synchronization` (all system) but must not import `SwiftUI` / `AppKit` or any
  sibling module.
- `UI` already depends on `Observability`, so the console view and view model
  consume these types with no new edges.
- The `Window` scene and the menu command live in `App` (per `App/CLAUDE.md`),
  which already depends on `UI`.
- No upward imports anywhere.

## Implementation plan

Each numbered step is one commit, small enough to hand to Sonnet on its own.
Scope is `feat(observability):` for steps 1-4, `feat(ui):` for 5-6 and 9,
`feat(app):` for 7, `feat(ui):` for 8, `docs:` for 10. After each step run
`make format && make lint && make build` and the relevant `make test-<module>`.

1. **`LogLevel` + `LogEntry` value types** in `Observability`, with tests.
   Pure data: `LogLevel` (Comparable ordering, `label`), `LogEntry` (fields +
   `Identifiable` by `id`). No wiring, nothing references them yet.
   Tests: ordering (`.debug < .warning`), `label` strings, `LogEntry` equality.

2. **`LogStore` ring buffer: `record` / `snapshot` / `clear`** behind a
   `Mutex`, with capacity eviction and a monotonic `nextID`. No streaming yet.
   Tests: appends in order; oldest dropped past capacity; `snapshot` order;
   `clear` empties; `isCaptureEnabled = false` makes `record` a no-op; ids
   strictly increasing; thread-safety smoke test (concurrent `record` from a
   `TaskGroup`, assert count and id monotonicity).

3. **`LogStore` live broadcast**: `backfillAndSubscribe()` returning
   `(backfill, AsyncStream)`, multi-subscriber, with `onTermination` cleanup.
   Tests: a subscriber sees only post-backfill lines; two subscribers each
   receive every new line; backfill + live has no gap and no duplicate across
   the seam; cancelling the consuming task removes the continuation (record
   afterwards does not leak / grow the subscriber map).

4. **Tee `AppLogger` into `LogStore`**: add `category` storage; each level
   records after building `msg`. Tests (`AppLoggerCaptureTests`): each of the
   seven levels produces one entry with the right `level` and `category`; the
   stored `message` equals what `format` produced; **sensitive keys are
   redacted in the captured entry** (log with `apiKey`/`token`/`password`,
   assert `<redacted>` in the stored message); disabling capture stops entries
   while `os.Logger` output is unaffected.

5. **`LogConsoleViewModel`** in `UI`: backfill + subscribe, batched flush,
   filtering (level/category/search), pause, clear view / clear buffer,
   `exportText` / `copyText`. Inject `LogStore` for testability. Tests
   (`LogConsoleViewModelTests`, host-less, run under `make test-coverage`):
   filter by minimum level; filter by category set; search substring; pause
   freezes `visible` but mirror keeps growing; clearView vs clearBuffer;
   `exportText` line format; `isAtCapacity` reflects the mirror. Drive the flush
   deterministically (inject the flush trigger / clock rather than sleeping, as
   the recent test-suite work did for debounce and RateLimiter).

6. **`LogConsoleView` + `LogConsoleRow`** in `UI`: toolbar (level / categories /
   search / pause / clear / copy / export / tail), the scrolling list with a
   `ScrollViewReader` for tail auto-scroll and a "Jump to latest" button, level
   color + `differentiateWithoutColor` text fallback, `textSelection`, empty
   state, a11y labels on every control and on rows. Wire `onAppear -> start()`,
   `onDisappear -> stop()`. Tests: a source-convention test asserting the
   controls / modifiers exist (host-less constraint), and a snapshot test in
   light + dark under `make test-ui`. Mind the 500-line SwiftLint
   `file_length`; split row rendering into `LogConsoleRow.swift`.

7. **App window + menu**: register `Window("Log Console", id: "log-console")`
   in `BocanApp.swift` hosting `LogConsoleView`; add a Help-menu command in
   `BocanCommands.swift` that calls `openWindow(id: "log-console")`, with the
   confirmed shortcut. Keep the view models passed as plain `let` (the menu-bar
   invalidation rule). Add a source-convention test that the command and window
   id exist. `make generate` if a new App test file is added.

8. **Diagnostics settings hooks**: in `DiagnosticsSettingsView`, an "Open Log
   Console" button (`openWindow(id:)`), a "Capture in-app logs" toggle bound to
   `LogStore.shared.isCaptureEnabled` (persist via `@AppStorage`
   `console.captureEnabled`, default true, applied on launch), and a read-out of
   buffer size / capacity. Test: source-convention asserting the button + toggle
   copy exist; toggling persists.

9. **Polish + export to file**: `Export…` save panel writing `exportText()` to a
   `.log`; "Copy" to clipboard; overflow menu "Clear Buffer"; capacity banner;
   auto-disengage Tail on user scroll-up (optional, behind the manual toggle if
   it proves fiddly); verify VoiceOver reaches every control and reads row
   level/category/message. Keep all user copy behind the `L10n` helper (the
   SPM-bundle localization rule), not bare `Text("…")`.

10. **Docs**: document the Log Console in `README.md` and the `/website` feature
    pages, and add a short "Viewing logs" entry under the in-app Help. No new
    third-party dependency, so `NOTICES` is unchanged. (No em dashes anywhere in
    docs / website / commit messages.)

## Dependencies

None new. No SPM packages, no Homebrew formulae, no entitlements. The only new
import is the system `Synchronization` module (for `Mutex`) inside
`Observability`.

## Context7 lookups

Run these before writing code:

- Apple `Synchronization`: `Mutex` usage, `withLock`, `Sendable` semantics on
  macOS 15. (Fallback: `os.OSAllocatedUnfairLock`.)
- Apple Swift Concurrency: `AsyncStream` with `onTermination`, and the pattern
  for fanning one producer out to multiple `AsyncStream`s.
- SwiftUI `Window` scene + `openWindow(id:)` and `@Environment(\.openWindow)`
  on macOS.
- SwiftUI `ScrollViewReader` / `scrollTo(_:anchor:)` for tail auto-scroll.

## Test plan

`Modules/Observability/Tests/ObservabilityTests/`:

- **`LogEntryTests`** / **`LogLevelTests`**: ordering, labels, identity.
- **`LogStoreTests`**: append order; capacity eviction; monotonic ids; capture
  on/off; backfill+subscribe seam (no gap, no dup); multi-subscriber fan-out;
  subscriber cleanup on cancellation; concurrent `record` safety.
- **`AppLoggerCaptureTests`**: per-level capture with correct level/category;
  message equals `format` output; redaction preserved in the captured entry;
  capture toggle.

`Modules/UI/Tests/UITests/`:

- **`LogConsoleViewModelTests`** (host-less): all filter dimensions; pause
  semantics; clearView vs clearBuffer; export/copy formatting; deterministic
  flush via injected trigger (no real sleeps).
- **`LogConsoleViewSnapshotTests`** (`make test-ui` only): populated console
  light + dark; empty state.
- Source-convention tests for the view controls and (in App) the menu command +
  window id.

Manual smoke: open the console, start a library scan, confirm debug lines tail
live; flip Tail off, scroll, flip on; set Level = Warning and confirm only
warnings+ show; search "subsonic"; Pause then Unpause and confirm backfill;
Export and open the file; toggle capture off in Diagnostics and confirm the
stream stops while terminal `log stream` still works.

## Acceptance criteria

- [ ] Help-menu "Log Console" and the Diagnostics button both open (or focus) a
      single window with id `"log-console"`.
- [ ] The window shows lines logged before it was opened (backfill from launch),
      oldest first, up to the buffer capacity.
- [ ] New lines tail live with Tail on, and stop auto-scrolling with Tail off;
      "Jump to latest" re-engages.
- [ ] `debug` and `info` lines appear (proving we are not limited to the
      `OSLogStore` notice-and-above set).
- [ ] Minimum-level filter, category multi-select, and search all work and
      compose together.
- [ ] Pause freezes the view; Unpause backfills missed lines (within capacity).
- [ ] Clear empties the view; "Clear Buffer" empties `LogStore` too.
- [ ] Copy and Export emit exactly the visible (filtered) lines.
- [ ] Captured messages are redacted: logging a field whose key is in
      `sensitiveKeys` shows `<redacted>` in the console and the export, never the
      secret.
- [ ] Capture has no perceptible effect on a library scan or playback start;
      the UI stays responsive during a high-rate log burst (batched flush holds).
- [ ] Turning "Capture in-app logs" off in Diagnostics stops new lines (and
      `record` becomes a no-op) without affecting `os.Logger` output.
- [ ] `Observability` still imports no sibling module and no `SwiftUI`/`AppKit`.
- [ ] All new tests pass; `make test-coverage` stays >= 80%; no SwiftLint /
      SwiftFormat warnings; no em dashes in docs/website/commits.

## Gotchas (the things that will bite you)

- **Never yield to stream continuations while holding the `Mutex`.** Copy the
  continuations under the lock, release, then yield. Yielding inside the lock
  invites re-entrancy and deadlock.
- **`record` must never recurse into `AppLogger`.** If `LogStore` or the console
  code needs to log a fault, it must do so in a way that cannot loop. Simplest
  rule: `LogStore` never logs.
- **Per-line UI updates will melt the main actor.** A scan or playback start
  emits log lines in bursts. The view model must coalesce at ~10 Hz, mirroring
  the existing scan-progress / debounce coalescing. Do not bind `visible`
  directly to a per-line append.
- **Backfill + live seam.** Subscribing and snapshotting must be atomic
  (`backfillAndSubscribe`), or you will drop or double-show the lines recorded
  between the two calls. The sequence id makes a dedupe safety-net cheap if you
  want belt-and-braces.
- **Capture is on from launch by design.** "Everything since it started" only
  holds if `record` is active before the first log line. Read the
  `console.captureEnabled` default and apply it during the same early bootstrap
  that starts logging, not lazily when the window opens.
- **AsyncStream buffering policy.** Use a bounded buffering policy
  (`.bufferingNewest(capacity)`) so a slow/paused consumer cannot make the
  stream grow without limit; the ring buffer is the real history, the stream is
  just the live tail.
- **Host-less tests.** The Xcode `BocanTests` bundle has no host app, so the
  view-tree pieces (`LogConsoleView`) get a source-convention test plus a
  snapshot under `make test-ui`; the view-model logic is fully unit-tested
  host-less. New files under `Tests/UITests/ViewModelTests` need `make generate`
  before `make test` / `make test-coverage` see them.
- **500-line `file_length`.** Split the row out (`LogConsoleRow.swift`) and keep
  the view lean; do not add a `swiftlint:disable`.
- **Localization.** User-facing strings go through the `L10n` helper
  (`Text(localized:)` / `L10n.string(_:)`), not bare `Text("…")`, or they will
  not resolve from the SPM module bundle.
- **Shortcut collision.** `Cmd-L` is Love. Confirm the console shortcut
  (suggested `Shift-Cmd-L`) is free in `BocanCommands` before claiming it.
- **`differentiateWithoutColor`.** The level badge must carry its text label,
  not rely on color alone, and the row a11y label must encode level + category
  + message.
- **Timestamp source.** Stamp `LogEntry.timestamp` at `record` time
  (wall-clock `Date`), and rely on the monotonic id for ordering. Do not sort by
  timestamp (two lines can share a millisecond); insertion order via id is the
  source of truth.

## Handoff

A later phase could, on top of this:

- Persist a rolling on-disk log (e.g. a size-capped file in
  `~/Library/Logs/Bocan/`) fed by the same `LogStore`, so logs survive a crash
  and can be attached to a GitHub issue next to the MetricKit report.
- Add structured-field inspection: store the redacted `fields` dictionary on
  `LogEntry` and render an expandable key/value view, not just the flat string.
- Add a second `LogStore` source backed by `OSLogStore` for `notice`+ history
  from *before* this launch, merged with the in-process buffer.
- A one-click "Copy diagnostics bundle" that zips the visible log, the latest
  MetricKit report, and the app/OS versions for bug reports.

When Phase 20 lands:

- `LogStore` is the single in-process tap on `AppLogger`; any future log UI or
  exporter consumes it rather than touching the facade again.
- The console window is decoupled from the capture mechanism, so swapping or
  augmenting the source does not touch the view.
