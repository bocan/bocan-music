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

- [ ] Enable Phone Sync, pair a real Android device with the code, sync a profile
      end to end. (22-4, 22-5, 22-6, 22-7, 22-8; the manual run above.)
- [ ] The manifest validates against `sync-protocol.md` and the shared fixtures;
      the Android `SyncApplier` accepts it unmodified. (22-5 + this slice.)
- [ ] Revoke immediately blocks a paired device at the TLS layer. (22-2/22-3;
      tested in 22-4.)
- [ ] Pairing golden vectors shared and green in both repos. (22-1 + this slice.)
- [ ] Range resume and If-Match staleness behave per contract (tested). (22-6.)
- [ ] Serving 10 GB to a phone leaves the UI responsive and writes nothing to the
      library. (Off-main handlers proven in 22-3/22-6; read-only by construction;
      a soak/large-file check recorded here.)
- [ ] All new user-facing strings localized; `make pseudolocale` green; snapshot
      tests updated. (22-8.)
- [ ] `make format`, `make lint`, `make build`, `make test-coverage` green; module
      coverage floor met. (Every slice; final full run here.)

Plus the Mac-repo "done" checklist from `_standards.md`:

- [ ] Every acceptance box across 22-0 through 22-9 ticked.
- [ ] `make format && make lint && make build && make test-coverage` green on the
      whole workspace (not just per-module).
- [ ] CI green on the PR(s).
- [ ] No `TODO(phase-22)` left behind.
- [ ] DAG docs (`_standards.md`, `CLAUDE.md`) reflect the `SyncServer` module and
      the `sync` log category; `project.yml` + `Makefile` (`test-sync-server`,
      coverage floor) updated; `make generate` clean.

## Read-only invariant (explicit final check)

Grep the `SyncServer` module for any write path into `tracks`, `playlists`,
`podcast_*`, or files under the library roots. There must be **none**: the module
only writes `trusted_devices`, `sync_meta` (generation/serverId), and
`sync_profile`. Serving performs zero library mutations. Document the check.

## Commits

One logical change per commit, Conventional Commits scoped by module across the
group (`feat(sync): ...` for the SyncServer module, `feat(persistence): ...` for
M031, `feat(ui): ...` for the settings pane, `docs: ...` for this slice). Each PR
links its phase file. No AI attribution / trailers. No em/en dashes in commit
messages, README, or website copy.

## Acceptance criteria

- [ ] README + website Phone Sync sections landed, dash-clean, consistent with
      existing feature docs.
- [ ] `pairing-vectors.json` and `manifest-small.json` committed and byte/value
      matched across both repos.
- [ ] Manual end-to-end run recorded in both PRs (or tracked as pending Android
      02/03 with an issue).
- [ ] Full acceptance sweep above complete; read-only invariant grep documented.
- [ ] Whole-workspace `make format && make lint && make build && make
      test-coverage` green; CI green; no `TODO(phase-22)` remains.

## Handoff (phase complete)

Phone Sync ships on the Mac side. The `SyncServer` module, the `sync_meta`
generation signal, and the `SyncProfile` model are the foundation for any future
LAN sync work; the Android phases 02 and 03 consume this server; a later Phase 18
remote-control server, if built, reuses none of this trust store but may share
extracted Bonjour/TLS/HTTP primitives.
