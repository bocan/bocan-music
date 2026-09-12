# Gotchas

Hard-won traps, procedures and settled decisions for this codebase. Each one cost a debugging session at least once. They are here, in the repository, because the agent's private memory is per machine: a different session, model or checkout starts without them.

Every entry has the same four parts. **Problem** is the symptom you will actually see. **Rule** is what to do. **Why** is the mechanism, so you can tell when the rule stops applying. **Canonical file** is where to look, verified against the tree when the entry was written or last touched.

This is not a style guide. The binding engineering rules live in `docs/design-spec/_standards.md`, and the architecture lives in the `CLAUDE.md` files. This file is for the things that are true but not deducible.

---

## SwiftUI observation and the menu bar

### MenuBarExtra `isInserted:` must bind to `@State`, never to storage

**Problem:** 100% CPU at launch, no tracks load, the app locks instantly. Or three "Publishing changes from within view updates" faults at the same timestamp.

**Rule:** Bind `isInserted:` to `@State` in the App struct, seeded from `UserDefaults.standard.bool(forKey:)` and persisted with `.onChange`. To let a Settings scene drive it, pass the binding through a custom `EnvironmentKey`, never through a shared `ObservableObject`.

**Why:** three separate routes to the same storm. An `@AppStorage` binding subscribes to the key-agnostic `UserDefaults.didChangeNotification`, which macOS fires constantly while autosaving window frames. A `@Published` binding re-enters the attribute graph when SwiftUI writes back to the setter. An `@AppStorage` inside a `@StateObject` in `App.body` does the same via `objectWillChange`. All three end in a full main-menu rebuild every run loop tick.

**Canonical file:** `Modules/UI/Sources/UI/Settings/MenuBarExtraKey.swift`

### Guard every `UserDefaults` mirror write on an actual value change

**Problem:** audio crackles while navigating. This is the bug the project nearly died to early on, and it came back in August 2026 through a new route.

**Rule:** any `didSet` that mirrors view-model state into `UserDefaults` for a menu-bar `@AppStorage` read must compare before writing:

```swift
if UserDefaults.standard.bool(forKey: key) != value {
    UserDefaults.standard.set(value, forKey: key)
}
```

Add the guard on the first write, not after a crackle report.

**Why:** `UserDefaults.set` broadcasts the key-agnostic change notification on every call, with no value-equality dedupe. `BocanCommands` subscribes through its own `@AppStorage` properties, so an unguarded mirror on a per-click property rebuilds the menu bar on the main thread during playback. Same mechanism as the `MenuBarExtra` traps above, reached from a different call site.

**Canonical file:** `Modules/UI/Sources/UI/ViewModels/LibraryViewModel.swift`

### Never share a bare enum `@AppStorage` between a menu and a view

**Problem:** the View menu changes the layout only sometimes. The in-view toggle always works.

**Rule:** store the raw value as a `String` and project the enum through a `DynamicProperty` wrapper. Any new menu-mirrored enum state uses that pattern.

**Why:** `@AppStorage` does not reliably deliver cross-instance invalidation for `RawRepresentable` values. The primitive overloads do. The menu writes its own instance; the view reads a different one on the same key. The tell is that every working menu mirror in `BocanCommands` is a `Bool`, and the one flaky mirror was the only enum.

**Canonical file:** `Modules/UI/Sources/UI/Browse/CollectionViewMode.swift`

### Gate menu items only on `@AppStorage` or `@Observable` reads

**Problem:** a menu item's `.disabled` state is frozen at the value it had when the body was built, and never revalidates, not even when the menu opens.

**Rule:** gate on `@AppStorage` or on `@Observable` state. Never on an `ObservableObject`'s `@Published` bridge. For radio-style gated items use checkmarked `Toggle`s, because a menu `Picker`'s option rows ignore `.disabled` entirely: the options stay clickable and only the header greys out.

**Why:** a `Commands` body re-evaluates only when a declared `@AppStorage` property or `@Observable` state it reads changes. The view models are passed as plain `let` on purpose, to keep the menu bar off the high-frequency render path, so nothing else can invalidate it. There is no per-open validation pass.

**Canonical file:** `App/BocanCommands.swift`

### The content area is destination-history, not a `NavigationStack`

**Problem:** adding a `NavigationStack` for album drill-down fights the existing model and does not work.

**Rule:** do not add one. Navigation replaces the detail view through a `@ViewBuilder switch` on the selected destination, and Back and Forward are custom toolbar buttons over `backStack` and `forwardStack`.

**Why:** the detail column deliberately swaps views rather than pushing, because of a macOS issue with `NavigationStack` in this position. Opening an album destroys the grid and builds the detail view, which is also why scroll position has to be captured and restored by hand rather than preserved.

**Canonical file:** `Modules/UI/Sources/UI/AppRoot/ContentPane.swift`

---

## AppKit hosts and the UI module

### Never write `drawableSize` inside `layout()`

**Problem:** the visualizer is a flat colour that still moves with the audio, or looks frozen. `NSDetectedLayoutRecursion` appears in the log.

**Rule:** there is no `layout()` override on the Metal view, and there must not be one. Do not give any renderer a `renderScale` below 1.0 until adaptive resolution renders offscreen and blits up.

**Why:** setting `drawableSize` during the layout pass triggers a nested layout that zeroes the view's bounds, so every later frame computes a 1x1 drawable stretched over the pane. The per-frame draw already applies the drawable size outside layout, so the override was redundant. It surfaced twice: once through a sub-1.0 render scale, once through a window that resizes every frame while animating.

Diagnose live-only visualizer bugs by logging the real per-frame uniforms from the renderer, not with more offscreen tests. Snapshot hosts pin the drawable size and never exercise the layout path.

**Canonical file:** `Modules/UI/Sources/UI/Visualizers/Metal/MetalVisualizerView.swift`

### `Podcast` and `PodcastEpisode` are ambiguous in the UI module

**Problem:** an honest "ambiguous for type lookup" error, followed by a misleading one: `Value of type 'PodcastRepository' has no member 'fetchByFeedURLIgnoringScheme'`. That member does exist, and there is only one `PodcastRepository`.

**Rule:** prefer a form that infers the type rather than annotating it. Where an annotation is unavoidable, qualify it: `Persistence.Podcast`, `Persistence.PodcastEpisode`.

**Why:** the UI module imports both `Persistence` and the Subsonic client, and each exports those names. Most UI code never writes them, so the clash stays hidden until someone needs an explicitly typed binding. The second error is overload resolution failing and blaming the wrong thing.

**Canonical file:** `Modules/UI/Sources/UI/Common/RecoveredRead.swift`

---

## Audio engine and playback

### Transport operations stay behind the async-mutex gate

**Problem:** silent playback with an advancing progress bar. In the log, the same pump stopped twice, or a start immediately followed by a stop with nothing scheduled.

**Rule:** the public `play`, `pause`, `seek` and `stop` call `acquireTransport()`, run the matching `performPlay` / `performPause` / `performSeek` / `performStop` body, then `releaseTransport()`. Any internal caller that already holds the gate must call the `perform*` variant directly or it deadlocks, which is why the seek resume and the default-device-change handler do. Any new entry point that mutates the pump or the player node must hold the gate for its whole body.

**Why:** the engine is an actor, but transport methods suspend partway through, and actor reentrancy lets a second call interleave at those suspension points and tear down the pump the first one just built. The player node keeps running, so time advances with nothing feeding it. Note that `load()` and the gapless end-of-track pump swap are not gated yet; if a track-change race shows the same symptom, extend the gate there.

**Canonical file:** `Modules/AudioEngine/Sources/AudioEngine/AudioEngine.swift`, regression test `Modules/AudioEngine/Tests/AudioEngineTests/EngineTransportTests.swift`

### Playlist edits mirror into Up Next through one bridge

**Problem:** editing a playing manual playlist used to leave stale items in the queue.

**Rule:** if the sync needs extending, to smart playlists or Subsonic playlists, follow the existing shape: a play entry point that takes the playlist id, a background task observing the playlist, and a sync function that branches on shuffle state. Every queue-replacing play method must stop the sync.

**Why:** sequential and shuffled queues need different reconciliation. Sequential reorders the whole queue and reuses item identities; shuffled removes and appends individually.

**Canonical file:** `Modules/UI/Sources/UI/ViewModels/LibraryViewModel+PlaylistSync.swift`

---

## Scanning, TagLib and feed parsing

### TagLib reads must use a read-only `FileStream`

**Problem:** a self-sustaining rescan loop over the same files forever, at the watcher's latency.

**Rule:** any new TagLib read path constructs `TagLib::FileStream(path, /* openReadOnly */ true)` and builds the `FileRef` from that stream. The stream must outlive the `FileRef`.

**Why:** `FileRef(path)` opens read-write by default. On files carrying a quarantine attribute, which the atomic temp-and-rename write stamps on everything the app rewrites, macOS updates provenance metadata on every write-intent open even with zero bytes written. That bumps ctime, which emits an FSEvents event, which re-triggers the rescan that did the read.

Related: FSEvents fires for metadata-only changes, so rescans are gated on size and mtime, and the conflict branch must not write unchanged rows or `ValueObservation` re-fires.

**Canonical file:** `Modules/Metadata/Sources/TagLibBridge/BocanTagLib.mm` (line 188 at time of writing)

### FeedKit models only two tags of the Podcasting 2.0 namespace

**Problem:** `podcast:funding`, `podcast:chapters`, `podcast:person` and `podcast:podroll` are simply absent from a parsed feed.

**Rule:** everything beyond `podcast:guid` and `podcast:transcript` comes from the supplementary `XMLParser` pass over the original bytes. Do not remove it until FeedKit models those tags. The supplement must match on namespace URI and accept both bindings feeds use in the wild, because publishers use either the current or the legacy one and the spec says to treat them as identical.

**Why:** FeedKit itself matches on prefix, so guid and transcript are URI-agnostic, which is why the gap is easy to miss.

**Canonical file:** `Modules/Podcasts/Sources/Podcasts/Parsing/PodcastNamespaceSupplement.swift`, background in `docs/design-spec/ADR-048-feedkit-upgrade.md`

---

## Persistence and keychain

### Credentials live in the plain login keychain with no accessibility class

**Problem:** intermittent "Server Unreachable" and "No server with id" disconnects.

**Rule:** do not set any `kSecAttrAccessible*` attribute on these items, and do not reintroduce the data-protection keychain.

**Why:** those attributes are data-protection only. Setting one on a legacy-keychain item is undefined behaviour per Apple TN3137 and caused intermittent read failures. A 2026-06 move to the data-protection keychain was reverted, and the provisioning-profile requirements were dropped with it, so this choice no longer constrains code signing.

**Canonical file:** `Modules/Scrobble/Sources/Scrobble/Auth/Credentials.swift`

### The debug build and the installed release app use different libraries

**Problem:** numbers quoted from "the library" are wrong, or a destructive change appears to have hit the real data when it did not, or the reverse.

**Rule:** before quoting anything from the library, find the running process and ask it which file it has open:

```
pgrep -x Bocan
lsof -p <pid> -F n | grep library.sqlite
```

Reading defaults reads the release app's preferences only.

**Why:** the bundle id is shared, but sandboxing decides the container. The debug build is sandboxed and uses the container path. The release build lost its entitlements in the deep re-sign step, so it is unsandboxed and uses the normal Application Support path. The two have diverged. Fixing the re-sign would silently move every user into an empty container on update, so it needs a migration plan rather than a one-line change. Both can run at once, which makes a log reading ambiguous.

**Canonical file:** `Scripts/build-release.sh`, entitlements in `Resources/Bocan.entitlements`

---

## Testing

### The XCUITest runner is sandboxed no matter what the project says

**Problem:** a UI test hangs mid-run with no dialog, or a file the test wrote is invisible to the app.

**Rule:** the app builds its own fixture world, keyed by an identifier passed in the launch environment, never a path. Never read file contents from the app's container in a journey; existence checks are safe and non-vacuity checks go through the UI. Use the real home from `getpwuid` when the runner needs true paths. Bind loopback only, and only after merging the network-server entitlement into the runner target.

**Why:** Xcode generates the runner's entitlements from a template and enforces the sandbox regardless of the project setting. Its read-only exception does not beat container protection: opening a directory parks forever on an unattended consent prompt. Its home points at the runner's own container, so writes get shadow-redirected where the app cannot see them. All-interfaces binding trips the local-network consent prompt and stalls forever unattended.

**Canonical file:** `App/E2ESeeder.swift`, runner entitlements in `UITests/BocanUITests.entitlements`

### Two deterministic causes of whole-suite E2E failure that look like a wedge

**Problem:** either every test fails with the fixture scan never producing rows, or fixtures seed fine but every window postcondition times out. Rebooting does not fix either.

**Rule:** diagnose from the captured evidence, not by rebooting. Export the result bundle's attachments, read the UI hierarchy text to see which window is actually up, and pull the last frame of the screen recording to see whether a modal dialog is covering everything. The launch arguments pin both causes: disable persistence, force the mini player closed, and disable sync.

**Why:** macOS scene restoration can reopen the mini player window at cold launch, and the mini player orders out the main window before bootstrap runs. Separately, enabling sync starts the Bonjour server, and an OS upgrade resets the local-network grant so the permission dialog returns and blocks the UI. Any future E2E-visible feature touching Bonjour needs the same treatment.

**Canonical file:** `UITests/Support/E2ESession.swift`, scene behaviour in `App/BocanApp.swift`

### Gesture at a visible anchor, never at an off-screen row

**Problem:** a coordinate tap silently lands on nothing, and scrolling the target itself fails outright with "Unable to find hit point".

**Rule:** whenever a test needs a list row that might be outside the viewport, scroll from a different element already known to be hittable, and re-check the target after each step. Use a large scroll step, around 300 points, not a small increment. After scrolling, still fall back to a coordinate tap, because macOS list rows report themselves as not hittable even when fully visible.

**Why:** rows below the fold still report an accessibility frame, but XCUITest cannot resolve a real screen point there, and scrolling needs a resolvable starting location too. Small steps can scroll the anchor itself off-screen before the target arrives, after which nothing works.

**Canonical file:** `UITests/Windows/SettingsCrawlTests.swift`

### Check `.value` as well as `.label`

**Problem:** an assertion against `.label` never matches an element you can see in a screenshot.

**Rule:** for any toast, banner or static-text assertion, check both attributes before concluding the feature is broken or the timing is wrong. Especially when the element carries an accessibility trait.

**Why:** AppKit's accessibility bridge maps static-text and live-updating roles to the value attribute rather than the description attribute, and XCUITest's `.label` reads the latter. This is decided by the trait stack, not by which SwiftUI API supplied the string. Confirmed on elements using the frequently-updating trait, text selection, and the static-text trait. This cost an entire session once: the toast was visible the whole time and the query was reading the wrong attribute.

**Canonical file:** `Modules/UI/Sources/UI/Common/ToastBanner.swift`

### Replace fixed sleeps with bounded waits

**Problem:** a test that passes locally fails on a loaded CI runner.

**Rule:** await the work deterministically instead of sleeping. Expose the timer task and await its value, or poll for the signal with a bounded timeout.

**Why:** a test that waits a fixed wall-clock interval for an async main-actor timer flakes when the runner starves the task past the wait. Several suites have been hardened this way; others with real-time waits remain and are known flake candidates rather than regressions.

**Canonical file:** `Modules/UI/Tests/UITests/ViewModelTests/VisualizerViewModelTests.swift`

### Capture the real exit code, and do not import GRDB into a `@testable` Persistence test

**Problem:** a broken test file gets committed because the gate reported success. Or a Persistence test target stops compiling with key-path ambiguity and type-checker timeouts.

**Rule:** redirect to a log, capture the status, then grep the log:

```
cmd > log 2>&1; r=$?; grep -E "error:|Test run" log | tail -3
```

Never gate on a piped grep, whose status is grep's. And in a test file that uses `@testable import Persistence`, do not add `import GRDB`; expose what you need as a static function taking the database and call that.

**Why:** the pipeline returns the last command's status, so a compile failure in the test target passes through an `&&` chain. The GRDB import makes key paths ambiguous between the two visible module scopes.

**Canonical file:** Makefile targets under `make test-<module>`

### Never put `allSatisfy` with a key path inside `#expect`

**Problem:** a test compiles under `swift test` but the Xcode bundle fails to build with `call can throw, but it is not marked with 'try'` pointing at `$0.allSatisfy($1)` inside a macro expansion. Writing it as a closure fixes it, and then `make format` puts the key path back and the build breaks again.

**Rule:** do not call a `rethrows` predicate method (`allSatisfy`, `contains(where:)`, `filter`) as the outermost expression of a `#expect`. Compare sets or hoist the result:

```swift
#expect(Set(rows.map(\.starred)) == Set([true]))
```

**Why:** the `#expect` macro decomposes the outermost boolean call into `$0.allSatisfy($1)` to build its failure message, and that rewrite loses the `rethrows` inference for a key-path argument. SwiftFormat's `preferKeyPath` rule rewrites `allSatisfy { $0.x }` into `allSatisfy(\.x)`, so a closure is not a stable workaround. `map(\.x)` is fine because it is not the outermost call.

**Canonical file:** `Modules/UI/Tests/UITests/ViewModelTests/SubsonicBrowseViewModelTests.swift`

### A test that stars a song can fail the transport-haptics test

**Problem:** `NowPlayingViewModelTests.transportHaptics` fails in a full `make test-ui` run with "Expectation failed: !patterns.contains(.levelChange)", and passes when run alone or with a few suites.

**Rule:** a test that writes a Subsonic star or rating for any reason other than testing the haptic wraps the call in `silencingHaptics { … }` (`SubsonicAnnotationCoordinatorTests.swift`). A test that is about the haptic installs its own recorder instead.

**Why:** `Haptics.performPattern` is one process-global closure. `transportHaptics` installs a recorder and keeps it installed across suspension points, so a `.levelChange` performed by any concurrently running test lands in its array. The helper swaps the seam and restores it with no suspension point in between, which makes the swap invisible to other `@MainActor` tests.

**Canonical file:** `Modules/UI/Sources/UI/Common/Haptics.swift`

### Diagnosing a frozen debug run

**Problem:** the app is unresponsive and it is not obvious whether it crashed, hung, or is paused.

**Rule:** check the process state first. A state of `X` means it is traced, so the debugger has it stopped. Then sample it twice. Every thread frozen at the same frame across both samples means the debugger stopped it, and the thread whose deepest frame is app or library code is the interesting one. Open files show what it was working on.

**Why:** a process that is technically alive tells you nothing about whether it is working. The symptom that matters is where the threads are, not whether the process exists.

**Canonical file:** not code; `ps -o state -p <pid>`, `sample <pid> 2`, `lsof -p <pid>`

---

## Tooling and repo

### The pre-commit hook is not strict; `make lint` is

**Problem:** a commit passes the hook and then fails CI on a size rule.

**Rule:** run `make lint` yourself before considering a change done. When a file tips over, extract a cohesive section into an extension file named for the type and the feature, the way `Modules/UI/Sources/UI/ViewModels/LibraryViewModel+PlaylistSync.swift` is, rather than adding a suppression.

**Why:** the hook runs SwiftLint non-strict, so warning-level rules pass at commit time, while `make lint` and CI run `--strict` and promote them to errors. The size rules are configured as a warning at 500 lines and an error at 700. Four source files already carry an explicit `file_length` suppression and should not gain company: `App/BocanApp.swift`, `Modules/UI/Sources/UI/ViewModels/LibraryViewModel.swift`, `Modules/UI/Sources/UI/ViewModels/NowPlayingViewModel.swift`, `Modules/UI/Sources/UI/Playlists/Smart/RuleRowView.swift`.

The same applies to cyclomatic complexity, which is capped at 10. The graph builder in `App/BocanApp.swift` sits at that limit, so adding any branching there means extracting a method, not suppressing the rule.

**Canonical file:** `.swiftlint.yml`

### Moving SPM pins takes more than a resolve

**Problem:** re-running the resolve, or even raising a manifest floor, does not move the pin. Downstream modules then fail on symbols that clearly exist.

**Rule:** bump the declared floor in the owning module's package manifest under `Modules/`, delete the workspace resolved-versions file, and if transitive pins still will not move, delete the derived-data source-packages directory, not just the user cache. Resolve, then verify with the drift script. Delete `Modules/*/.build` before running module suites. Dependency changes get the full suite.

**Why:** the resolve anchors on the existing resolved file and on cached repository mirrors, which do not know about new tags, so it can silently keep a version below a new floor. Stale module build plans fail to see files recently added to a dependency.

Two follow-on hazards. A stale explicit-modules cache produces a precompile failure whose real error only appears in raw build output, and only deleting the whole derived-data directory clears it. Never delete derived data while Xcode has the project open, because it immediately re-resolves into it and both operations fail.

**Canonical file:** `Scripts/check-package-updates.py`

### Fresh SwiftPM clones hang because of the git fsmonitor

**Problem:** a build with a new derived-data path, or a Periphery scan, sits at zero CPU forever with every package already cloned.

**Rule:** prefix the spawning command with `GIT_CONFIG_PARAMETERS="'core.fsmonitor=false'"`. If something is already stalled, sample it and look for a git checkout frame in the stack, then kill it and rerun with the prefix. Do not run two Periphery scans at once; they share a derived-data folder and the second waits on the lock.

**Why:** the fsmonitor is enabled globally on this machine. Each fresh clone starts a monitor daemon, and the checkout waits on it and never returns. Builds into the repository's own derived data do not hit it.

**Canonical file:** `Scripts/vital-signs.sh`, which already does this for its release build and scan

### Do not hand-fix String Catalog churn

**Problem:** thousands of lines of reordering in the catalogue after an Xcode build, plus newly extracted keys with no pseudolocale variant, which fails the coverage gate.

**Rule:** run `make pseudolocale`. It re-serialises the catalogue into the committed canonical form and generates the missing variants. Commit the small residue on its own.

**Why:** extraction runs during Xcode builds and serialises in a different order than the committed form.

**Canonical file:** `Modules/UI/Sources/UI/Resources/Localizable.xcstrings`

### Capturing a usable performance trace

**Problem:** a trace that contains none of the app's own signpost spans.

**Rule:** arm a system-wide recording first, then launch the app with `open`. Do not use the launcher's own launch flag. Build without the thread sanitizer for real numbers. Emit signposts to the points-of-interest log, not a custom category.

**Why:** launching through the trace tool makes AppKit relaunch into a second process, and only the first is signpost-enabled, so the real worker's spans are never captured. The scheme has the thread sanitizer on, which roughly doubles timings, and an incremental build will not relink off the cached sanitizer runtime. A custom signpost category is not enabled by the default recording configuration, so intervals silently do nothing.

An all-process save can spin for ten minutes and never finish. To verify a single post-launch interaction, attach to the running process instead: the trace is small and saves in seconds. Any `@AppStorage` key can be passed as a launch argument, which is how a specific surface gets put on screen before recording.

**Canonical file:** `Modules/Observability/Sources/Observability/Telemetry.swift`

### Verify a push by refs, never by grepping its output

**Problem:** a retry loop reports success while the mirror sits on an orphaned commit. Or a rebase reports success and a local commit is gone.

**Rule:** compare `git ls-remote <url> refs/heads/main` against the local tip. After any `git pull --rebase`, check the log for your commit before pushing; if it is missing it is still in the reflog and can be cherry-picked. Prefer fetch plus an explicit rebase onto the remote branch.

**Why:** grepping for a success pattern also matches the rejection line, which contains the same branch mapping. A "successful" rebase is not proof the commits survived; a fork-point misfire can check out the new upstream head and never replay local work, leaving a clean-looking tree.

**Canonical file:** not code; `git ls-remote`, `git reflog`

### `origin` is GitHub only; the mirrors are a separate remote

**Problem:** a fresh clone silently loses the mirrors, because this is local git configuration.

**Rule:** the mirrors live on a second remote with two push URLs, pushed by hand. When restoring it, add the fetch URL explicitly as a push URL too.

**Why:** the moment any push URL is added to a remote, git stops using the fetch URL for pushes, so the mirror that is also the fetch URL gets silently skipped. Verify with `git remote -v`: the backup remote should show one fetch line and two push lines.

**Canonical file:** not code; `git remote -v`

### Repeat the closing keyword for every issue a PR closes

**Problem:** a merged PR closes only the first issue in its list.

**Rule:** write `Closes #1. Closes #2.` and not `Closes #1, #2`. After merging a PR that closes several issues, check that they actually closed.

**Why:** the keyword applies only to the reference immediately after it. The usual safety net, a closing line in each branch commit, does not exist here because the repository squash merges and the branch commits disappear. This repository's audit pattern produces one issue per module landed by a single PR, so the shape recurs.

**Canonical file:** not code; see the git history of PR #500

### When a tool moves, move the pin forward

**Problem:** a Homebrew update breaks a gate.

**Rule:** bump the pin to the installed version on a chore branch, fix every new violation properly rather than with disable comments, and run the full gates. Do not install or pin an older version to get a green gate.

**Why:** the project is kept working against current tooling, deliberately. A relinked FFmpeg additionally leaves stale build manifests naming the removed directory, which a scheme clean fixes, and a major bump also needs the bundled helper rebuilt.

**Canonical file:** `.swiftlint-version`, `.swiftformat-version`

---

## Decisions not to revisit

### Follow-the-playhead track centring

Built in full, tried, and rejected on 2026-08-31: "Now that I've tried it, I don't like it." The behaviour felt wrong in practice; this is not a bug report about the implementation. Do not re-suggest auto-scrolling or centring the tracks list when playback advances.

### The locked-looking spectrum bars on internet radio

Observed and explicitly accepted on 2026-05-27. The top few bars sit at the same level because low-bitrate streams low-pass well below Nyquist, so those FFT bins all land in the near-zero floor. That is an honest spectrogram of a band-limited signal, not a bug. If a softening is ever wanted, it will be asked for.

### The data-protection keychain

Tried in June 2026 and reverted. See the keychain entry above for what stays true.

### A `NavigationStack` in the detail column

See the content navigation entry above. The destination-history model is deliberate.

### The Android companion's stack

Settled in the sibling repository and not to be relitigated: Kotlin with Compose, Media3 with the FFmpeg decoder extension, Room, manual dependency injection. Sync is strictly one way, Mac to phone, over the LAN. The phone edits nothing. The wire contract in that repository is normative for both sides; the Mac half is specified in `docs/design-spec/ADR-060-phone-sync.md` and the ADRs that follow it.
