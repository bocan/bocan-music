# Phase 35: E2E Nightly Pipeline (Two Tiers)

> Prerequisites: Phases 28-34 (any subset already landed benefits
> immediately; this phase can start once 28 exists and grow). The agreed
> model: a small smoke subset on GitHub-hosted macOS runners per push, and
> the full crawl nightly on a self-hosted Mac with a real GPU. Runtime for
> the full board is expected in the 1-3 hour range, which is fine at
> night; the design goal is that a failure files itself and is triaged in
> the morning, so no breakage waits a month for a human to stumble on it.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Two workflows, a runner, retry/quarantine policy, artifact collection, and
self-filing failure reports.

## Non-goals

- Growing test content (owned by phases 28-34).
- Release-blocking E2E: the normal pipeline stays as-is; E2E gates
  nothing initially (revisit once flake rate proves out).

## Implementation plan

1. **Tagging model.** Swift Testing-style tags via XCTest test plans:
   `Smoke` (a curated <=10 minute subset: phase 28 journeys, menu
   structural crawl, one surface, one radio journey), `Full` (everything),
   `GPU` (phase 33 matrix), `Tooltip` (quarantinable hover checks). Two
   `.xctestplan` files check the tags in.
2. **Per-push smoke (`e2e-smoke.yml`).** GitHub-hosted `macos-latest`,
   runs the Smoke plan on pushes to main, time-boxed 20 minutes,
   non-required check initially.
3. **Nightly full (`e2e-nightly.yml`).** Cron 02:00 UTC + dispatch, runs
   the Full plan on the self-hosted runner, one automatic retry of failed
   tests via `-retry-tests-on-failure -test-iterations 2`, uploads the
   `.xcresult`, extracted screenshots, and screen recordings as artifacts.
4. **Self-hosted runner, with the security model in bold.** This repo is
   public; a naive self-hosted runner would execute fork PRs on your Mac.
   Mitigations, all mandatory: the runner is labeled and used ONLY by the
   nightly workflow; workflows on `pull_request` never target the label;
   repository setting "require approval for all outside collaborators"
   stays on; the runner runs as an unprivileged user in a dedicated macOS
   login with nothing else on it; and the nightly workflow triggers only
   on `schedule`/`workflow_dispatch` from main. Document the setup in
   `DEVELOPMENT.md` (runner install, keeping the machine awake via
   `caffeinate`/pmset schedule, auto-update policy).
5. **Self-filing failures.** On a red nightly, the workflow opens or
   refreshes a single "Nightly E2E failures" issue (`dependency-drift`
   pattern): failed test names, first failure screenshots inline, links
   to the artifact bundle. Green nights close nothing and post nothing.
6. **Flake ledger.** A `UITests/QUARANTINE.md` listing quarantined tests
   with date and reason; the nightly report counts quarantined tests so
   the ledger cannot silently grow. A quarantined test still runs, its
   failure just does not redden the night; two clean weeks earns
   un-quarantine.
7. **Makefile.** `make test-e2e` (Full, local), `make test-e2e-smoke`
   (Smoke, local).

## Test plan

- Smoke workflow green on a real push; nightly green on a real night;
  a forced failure (temporarily broken assertion via dispatch run) files
  the issue with screenshots, and the next green run leaves it for a
  human to close.

## Acceptance criteria

- [ ] Smoke plan <=10 minutes on GitHub-hosted hardware.
- [ ] Nightly runs unattended on the self-hosted runner and uploads
      artifacts.
- [ ] All five security mitigations verifiably in place before the runner
      label is created.
- [ ] Failure issue automation demonstrated end to end.
- [ ] Quarantine ledger wired into the nightly report.

## Gotchas

- XCUITest needs a logged-in GUI session on the runner Mac: no fast user
  switching away from the runner account, screen lock disabled for that
  account, and `sudo pmset repeat wakeorpoweron` for the schedule.
- Screen recordings balloon artifact storage; keep 7 days' retention and
  only record on failure (`-test-repetition-relaunch-enabled` plus
  xcresult attachment policy).
- GitHub-hosted macOS runners throttle Metal and sometimes lack windows
  server quirks; any test that proves GitHub-tier-flaky but GPU-tier-solid
  moves to the Full plan rather than living in quarantine.

## Handoff

The programme becomes steady-state: new features add their controls to
phase 29's audits and phase 31's tables as part of the feature's own
phase, and the nightly board keeps them honest from the first night.
