# Contributing to Bòcan

Thank you for your interest in contributing.

## Before you start

- Read `DEVELOPMENT.md` for environment setup.
- Read `phases/_standards.md` — all code must comply.
- Check for an existing issue or open one to discuss your idea first.

## Commit conventions

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(audio): add gapless handoff scheduling
fix(library): handle symlinks in FSEvents watcher
chore(deps): update GRDB to 6.28.0
```

Scopes match module names: `audio`, `library`, `metadata`, `persistence`, `ui`, `playback`, `cast`, `scrobble`, `observability`.

## Pull requests

- One logical change per PR.
- Link the relevant phase spec file in the PR description.
- All acceptance criteria for the relevant phase must be checked before merge.
- `make lint && make test-coverage` must be green.
- No force pushes to `main`.

## Code style

Run `make format` before committing. The pre-commit hook (installed by `make bootstrap`) runs `swiftformat --lint` and `swiftlint` automatically.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md).

## Security issues

See [SECURITY.md](SECURITY.md).
