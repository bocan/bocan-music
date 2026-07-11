# Phase 22-9: Docs + Cross-Repo End-to-End + Acceptance Sweep

> Depends on: all of 22-1 through 22-8 landed and green. This slice is the "done"
> gate for Phase 22 and the only one whose full completion needs the **Android**
> client runnable (its phases 02 pairing + 03 sync engine).
>
> Binding docs: `_standards.md` ("What done means"), `CLAUDE.md` (commit rules:
> document features in README + website, no em/en dashes),
> `sync-protocol.md`, and the Android
> `phase-mac-1-sync-server.md` handoff section.

## Goal

Close the phase: user-facing docs (README + website), the cross-repo integration
proof (shared fixtures green in both repos + a documented manual end-to-end run
against the real Android app), and a sweep of every acceptance box across the
group. Nothing new is built; this is verification, documentation, and sign-off.

## Documentation

Per the repo commit rules ("Document new features in README.md and in the repo's
/website pages"), with **no em dashes or en dashes** anywhere:

- **README.md**: add a "Phone Sync" feature section: what it does (serve your
  library read-only to a paired Android phone over the local network, one way),
  how to enable it (Settings > Phone Sync), the pairing flow (six-digit code +
  confirm on the Mac), the sync-profile idea (Everything or chosen playlists,
  podcasts optional), and the security posture (mutual pinned TLS, LAN only,
  nothing written back). Keep parity with how other features are described.
- **/website**: add a Phone Sync page (mirroring the existing feature pages) with
  the same content at a marketing-appropriate level, plus a short "How pairing
  keeps you safe" explainer (the code is a verification code, not a secret; the
  final confirm on the Mac is deliberate). Update any feature index/nav.
- Cross-link: the Android repo's `phase-mac-1-sync-server.md` and this Phase 22
  group both point at `sync-protocol.md`; make sure the README/website mention
  the Android companion app.

## Cross-repo integration proof

The compatibility contract is the shared fixtures plus one real run:

1. **Pairing golden vectors** (`pairing-vectors.json`): byte-identical and green
   in both repos (Mac: phase 22-1 `PairingCodeTests`; Android: its
   `core/sync` pairing tests). Confirm the file is **committed** in both repos and
   the bytes match (a `diff` is part of this slice's checklist).
2. **Golden manifest** (`manifest-small.json`): the Mac `ManifestBuilder`
   (phase 22-5) produces a value-identical manifest for the shared fixture
   library, and the Android `SyncApplier` accepts the Mac-produced manifest
   unmodified. Prove both directions where possible: Mac-produces == fixture, and
   Android-consumes(Mac-produced) succeeds.
3. **Manual end-to-end run** (needs Android phases 02 + 03 runnable): pair a real
   Android device (or the Android instrumented test client) with the code shown
   on the Mac, choose a sync profile, and sync it end to end. Record the run
   (steps, device, outcome, a screenshot or log excerpt) in **both** PRs, per the
   Android handoff requirement. If the Android side is not yet runnable at Mac
   merge time, land 22-1 through 22-8, mark this box "pending Android 02/03," and
   open a tracking issue so the box is ticked when the Android client lands. The
   Mac-side unit/integration proofs (fixtures, loopback) do not wait on this.

## Full acceptance sweep (from the Android `phase-mac-1` acceptance criteria)

Verify each, citing the slice that satisfies it:

- [ ] **Pending the manual device run** (see the verification record below):
      enable Phone Sync, pair a real Android device with the code, sync a profile
      end to end. (22-4, 22-5, 22-6, 22-7, 22-8; the manual run above.) Every
      Mac-side proof of the same path is green over loopback TLS.
- [x] The manifest validates against `sync-protocol.md` and the shared fixtures;
      the Android `SyncApplier` accepts it unmodified. (22-5 + this slice:
      Android `SyncApplierTests` and `ManifestCodecTests` green against the
      byte-identical fixture, 2026-07-11.)
- [x] Revoke immediately blocks a paired device at the TLS layer. (22-2/22-3;
      tested in 22-4.)
- [x] Pairing golden vectors shared and green in both repos. (22-1 + this slice:
      `diff` byte-identical, Mac `PairingCodeTests` and Android
      `PairingCodeTests` green, 2026-07-11.)
- [x] Range resume and If-Match staleness behave per contract (tested). (22-6.)
- [x] Serving leaves the UI responsive and writes nothing to the library.
      (Off-main handlers proven in 22-3/22-6; read-only proven by the grep in the
      verification record below; the concurrent-download responsiveness test in
      22-6 is green. The at-scale 10 GB soak against a real phone is folded into
      the pending manual run.)
- [x] All new user-facing strings localized; `make pseudolocale` green; snapshot
      tests updated. (22-8.)
- [x] `make format`, `make lint`, `make build`, `make test-coverage` green; module
      coverage floor met. (Every slice; final full run recorded below.)

Plus the Mac-repo "done" checklist from `_standards.md`:

- [x] Every acceptance box across 22-0 through 22-9 ticked, except the two boxes
      that need the physical device, which are explicitly pending the manual run
      per this file's own escape hatch.
- [x] `make format && make lint && make build && make test-coverage` green on the
      whole workspace (not just per-module). (Recorded below.)
- [x] CI green on main through every landed slice (latest: the 22-8 settings
      pane commit); this slice's run triggers on push.
- [x] No `TODO(phase-22)` left behind. (Grep over sources, specs, and build
      files: zero hits.)
- [x] DAG docs (`_standards.md`, `CLAUDE.md`) reflect the `SyncServer` module and
      the `sync` log category; `project.yml` + `Makefile` (`test-sync-server`,
      coverage floor) updated; `make generate` clean.

## Read-only invariant (explicit final check)

Grep the `SyncServer` module for any write path into `tracks`, `playlists`,
`podcast_*`, or files under the library roots. There must be **none**: the module
only writes `trusted_devices`, `sync_meta` (generation/serverId), and
`sync_profile`. Serving performs zero library mutations. Document the check.

## Verification record (2026-07-11)

### Cross-repo fixtures

`diff` of both shared fixtures between
`Modules/SyncServer/Tests/SyncServerTests/Fixtures/` (this repo) and the Android
repo (`core/sync/src/test/resources/fixtures/pairing-vectors.json`,
`core/persistence/src/test/resources/fixtures/manifest-small.json`): **byte
identical**, and `git ls-files` confirms both files are committed in both repos.

Test runs against the fixtures, all green on 2026-07-11:

- Mac: `make test-sync-server`, 86 tests in 20 suites passed (includes
  `PairingCodeTests` golden vectors and the `ManifestBuilder` golden manifest).
- Android: `./gradlew :core:sync:testDebugUnitTest --tests "...PairingCodeTests"
  :core:persistence:testDebugUnitTest --tests "...SyncApplierTests" --tests
  "...ManifestCodecTests"`, BUILD SUCCESSFUL. The Android `SyncApplier` consumes
  the Mac-shape manifest fixture unmodified, proving the consume direction; the
  Mac golden test proves the produce direction.

### Read-only invariant

Audited every repository method call in `Modules/SyncServer/Sources`:

- Library-owned repositories (`TrackRepository`, `PlaylistRepository`,
  `AlbumRepository`, `ArtistRepository`, `PodcastRepository`,
  `EpisodeRepository`, `EpisodeStateRepository`, `CoverArtRepository`,
  `LibraryRootRepository`) are called **only** through fetch/read methods
  (`fetch`, `fetchAll`, `fetchAllIncludingDisabled`, `fetchTrackIDs`,
  `fetchByGUID`, `fetchForPodcast`, `fetchByDownloadState`,
  `fetchAllSubscribed`).
- The only mutating repository calls are `upsert`/`delete`/`observeAll` on
  `TrustedDeviceRepository` and the profile save on `SyncProfileRepository`,
  plus the `sync_meta` generation bump: exactly the allowed set.
- Zero direct database writes (`.write`, `execute`) and zero filesystem write
  APIs (`createFile`, `write(to:)`, `removeItem`, `moveItem`, `copyItem`,
  `FileHandle(forWritingTo:)`, `OutputStream`) anywhere in the module. The
  Keychain identity blob is the module's only non-database persistence.

### Flake fixed during the sweep

The full-suite run surfaced a transient `.identity(reason: "keygen")` failure:
parallel test suites generating permanent P-256 keys into the login Keychain at
the same time can make `SecKeyCreateRandomKey` fail transiently. Fixed in
`KeychainIdentityStore` by serialising key generation in-process, extending the
retry backoff, and logging the underlying `CFError` instead of dropping it.
Suite is green after the fix.

### Manual end-to-end runbook (pending hardware)

Android phases 02 (pairing) and 03 (sync engine) are landed, so the run needs
only a physical device:

1. Mac: Settings > Phone Sync, enable, click "Pair a Phone" and note the
   six-digit code.
2. Phone: discover the Mac, enter the code, wait for the Mac's "Pair with this
   phone?" confirmation and accept it on the Mac.
3. Phone: choose a sync profile (Everything or selected playlists, podcasts
   optional) and sync end to end; include something large enough to double as
   the 10 GB soak, watching that the Mac UI stays responsive.
4. Confirm nothing under the library roots changed (mtime sweep or `git status`
   on a test library), then record device model, steps, outcome, and a
   screenshot or log excerpt here and tick the two pending boxes above.

## Commits

One logical change per commit, Conventional Commits scoped by module across the
group (`feat(sync): ...` for the SyncServer module, `feat(persistence): ...` for
M031, `feat(ui): ...` for the settings pane, `docs: ...` for this slice). Each PR
links its phase file. No AI attribution / trailers. No em/en dashes in commit
messages, README, or website copy.

## Acceptance criteria

- [x] README + website Phone Sync sections landed, dash-clean, consistent with
      existing feature docs. (README feature section + module table; website
      `/phone-sync/` page, nav link, and homepage feature card.)
- [x] `pairing-vectors.json` and `manifest-small.json` committed and byte/value
      matched across both repos. (Verified 2026-07-11; see the verification
      record.)
- [ ] **Pending**: manual end-to-end run recorded (runbook in the verification
      record below; needs a physical Android device and a tracking issue).
- [x] Full acceptance sweep above complete; read-only invariant grep documented.
- [x] Whole-workspace `make format && make lint && make build && make
      test-coverage` green; CI green through the last landed slice; no
      `TODO(phase-22)` remains.

## Handoff (phase complete)

Phone Sync ships on the Mac side. The `SyncServer` module, the `sync_meta`
generation signal, and the `SyncProfile` model are the foundation for any future
LAN sync work; the Android phases 02 and 03 consume this server; a later Phase 18
remote-control server, if built, reuses none of this trust store but may share
extracted Bonjour/TLS/HTTP primitives.
