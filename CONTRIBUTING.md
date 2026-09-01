# Contributing to Bòcan

Thank you for your interest in contributing.

## Before you start

- Read `DEVELOPMENT.md` for environment setup.
- Read `docs/design-spec/_standards.md` — all code must comply.
- Check for an existing issue or open one to discuss your idea first.

## Commit conventions

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(audio): add gapless handoff scheduling
fix(library): handle symlinks in FSEvents watcher
chore(deps): update GRDB to 6.28.0
```

Scopes match module names: `audio`, `library`, `metadata`, `persistence`, `ui`, `playback`, `cast`, `scrobble`, `observability`.

## Branches and pull requests

`main` is the trunk and is never committed to directly. Work on a short-lived
branch named `<type>/<slug>` (`fix/349-album-grid-scroll-restore`), push it as
often as you like (pushes run only a lint, build and secret scan), and land it
with a pull request.

- One logical change per branch and per PR. A PR is a feature or a fix, never
  a release; releases are cut from `main` separately.
- The PR title must be a Conventional Commit (`fix(subsonic): retry failed
  logins`); it becomes the squash commit on `main` and drives the version bump.
- A `feat`, `fix` or `perf` PR must add a short, user-facing note under
  `## [Unreleased]` in `CHANGELOG.md`. It becomes the release notes and the
  Sparkle update prompt. Label the PR `skip-changelog` if the change is not
  user-visible.
- `make lint && make test-coverage` must be green locally; the PR runs the
  full suite.
- Merges are squash-only. No direct or force pushes to `main`.

## Code style

Run `make format` before committing. The pre-commit hook (installed by `make bootstrap`) runs `swiftformat --lint` and `swiftlint` automatically.

## AI-assisted contributions

Contributions written with AI assistance are entirely welcome, on the same
terms as any other: the existing coding standards apply in full, and every PR
gets a thorough human review regardless of who or what typed it.

If you point a coding assistant at this repo, give it the same context a
human contributor reads: `DEVELOPMENT.md` for environment setup and the
binding standards in `docs/design-spec/_standards.md`. The repo also carries
`CLAUDE.md` files (at the root and recursively in `App/` and several
`Modules/*/` directories) with the project's conventions and sharp edges;
they are written for Claude but are plain markdown, so feed them to whatever
assistant you use.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md).

## Security issues

See [SECURITY.md](SECURITY.md).
