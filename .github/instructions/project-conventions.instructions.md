---
description: "Use when selecting versions of tools, SDKs, runtimes, GitHub Actions, Homebrew formulas, Swift Package Manager dependencies, or Xcode; and when writing git commit messages. Enforces latest-version policy and Conventional Commits for the bocan-music project."
applyTo: ["**/Package.swift", "**/project.yml", ".github/workflows/**", "Brewfile", ".github/dependabot.yml"]
---

# bocan-music project conventions

## Always use the latest versions

Default to the newest available stable version of every tool, SDK, runtime, dependency, and action. Never pin to an older version for comfort, LTS, or perceived stability unless there is a concrete, documented reason (e.g. an upstream incompatibility that cannot be worked around).

**Applies to:**

- **Xcode**: the highest stable Xcode available on the macOS runner (`macos-<N>`). Update `xcodeVersion` in `project.yml` and the `xcode-select` path in `.github/workflows/*.yml` together.
- **GitHub Actions runners**: the newest `macos-<N>` image, not `macos-latest` (pin explicitly to the newest numeric image for reproducibility).
- **GitHub Actions versions**: latest major tag on every action (`actions/checkout@v6`, `actions/cache@v5`, `github/codeql-action@v4`, etc.). When a new major ships, bump.
- **Swift toolchain / language mode**: highest stable Swift (`SWIFT_VERSION` in `project.yml`, `swift-tools-version` in every `Package.swift`).
- **SPM dependencies**: latest released version in every `Package.swift` across all modules. Avoid `exact:` or `upToNextMinor` unless there is a breaking-change reason; prefer `from:` with the newest known tag and let Dependabot bump.
- **Homebrew formulas** in `Brewfile`: no version pins. Rely on the latest available.
- **Dependabot**: cover every SPM manifest and `github-actions`; prefer `daily` over `weekly` so bumps arrive fast.

When bumping a version also causes a code change, include the reason in the commit body — not just "bump X".

## Conventional Commits

Every commit message must follow [Conventional Commits 1.0](https://www.conventionalcommits.org/).

**Format:**

```
<type>(<scope>): <imperative, lowercase, no trailing period>

<body — wrap at ~72 columns, explain *why* not *what*>
```

**Allowed types** (match the project's existing history):

`feat`, `fix`, `build`, `ci`, `docs`, `test`, `refactor`, `perf`, `style`, `chore`, `revert`.

**Scopes** (non-exhaustive, one per commit; lowercase):

`audio`, `library`, `persistence`, `metadata`, `playback`, `ui`, `observability`, `readme`, `deps`, plus ad-hoc scopes where they add clarity.

**Breaking changes:** append `!` after the scope (`feat(persistence)!: ...`) and include a `BREAKING CHANGE:` footer explaining the migration.

**Examples from this repo:**

- `fix(library): repair FSWatcher event delivery; clean Library warnings`
- `test(persistence): skip performance suite on CI (runner variance)`
- `ci: bump runners to macos-26 + Xcode 26.4`
- `build(audio): hardcode Homebrew include/lib paths on AudioEngine`

**Don't:**

- Use past tense ("fixed", "added") — use imperative ("fix", "add").
- Capitalise the subject or end it with a period.
- Cram multiple unrelated changes into one commit — split them.
- Skip the body when the diff isn't obvious; explain *why*.
