# Localization workflow (#314)

How user-facing copy in the `UI` module gets localized, how to convert a screen,
and how the regression guard keeps converted screens converted. The foundation
(catalog, `L10n` helper, reference conversion of `AlbumsGridView`) landed in
68d3dab; this document is the recipe every follow-up conversion uses.

## Decision record: per-call-site `L10n`, not `Bundle.main`

Two ways to make a String Catalog resolve from an SPM module were considered:

1. **Per-call-site helper (chosen).** The catalog lives in the module
   (`Modules/UI/Sources/UI/Resources/Localizable.xcstrings`) and every call
   site resolves it explicitly via `Text(localized:)` / `L10n.string(_:)`,
   which pass `bundle: .module`.
2. **Host the catalog in the app target.** Bare `Text("…")` literals would then
   resolve against `Bundle.main` and "just work" at runtime.

Option 1 stands because it is explicit and testable: the strings ship with the
module that owns the views, `make test-ui` can validate catalog content without
the app target, previews and any future second consumer of the module keep
working, and the conversion state of a file is visible in the source (a bare
literal is by definition unconverted). Option 2 would couple every UI string to
the app target and make "localized or not" invisible at the call site. Do not
revisit this without updating this document and #314.

## Why a helper is needed at all

SwiftUI's `LocalizedStringKey` initializers (`Text("…")`, `Button("…")`,
`.navigationTitle("…")`, `.help("…")`, alerts, and friends) resolve against
`Bundle.main` by default. The `UI` module's catalog ships in `Bundle.module`,
so a bare literal in this module compiles fine, renders fine in English, and
silently never localizes. Every user-facing string must therefore go through
`Modules/UI/Sources/UI/Localization/L10n.swift`:

- `Text(localized: "Albums")` for SwiftUI text.
- `L10n.string("Play \(count) Albums")` for APIs that take a plain `String` or
  a bundle-less `LocalizedStringKey`: `.navigationTitle`, `.help`, `Button(_:)`,
  `Toggle(_:)`, alerts, view-model copy, and all AppKit cell strings
  (`setAccessibilityLabel`, `stringValue`, `toolTip`), which get no
  `LocalizedStringKey` treatment at all.

## Converting a screen (the per-task recipe)

1. **Convert literals.** SwiftUI text becomes `Text(localized: "…")`;
   bundle-less APIs and AppKit strings become `L10n.string("…")`.
2. **Classify interpolations.** Each `"… \(x) …"` is either a **plural**
   (counts) or a **format** (names, values). Plurals become one catalog key
   with `one`/`other` variations whose `one` reproduces the old singular
   exactly. Foundation generates `%lld` for `Int` and `%@` for `String`
   arguments; the catalog key must match those tokens (for example
   `"Play \(ids.count) Albums"` keys as `Play %lld Albums`).
3. **Add catalog entries** to `Resources/Localizable.xcstrings` (hand-edit the
   JSON or use Xcode's catalog editor). Keep English values byte-identical to
   the old literals so snapshot tests do not drift.
4. **Verify.** `make build` (only Xcode compiles the catalog; confirm no
   warnings) and `make test-ui` (snapshots must be unchanged, since English
   values match the old literals).
5. **Extend `L10nTests`** with catalog-content assertions for any new plural
   keys (see "Testing strategy" below for why content, not runtime).
6. `make format && make lint && make test-coverage`; commit
   `feat(ui): localize <area> (#314)`; tick the box in the #314 roadmap.

## Regression guard

`.swiftlint.yml` defines a custom rule, `no_bare_user_facing_literal`, that
flags bare string literals at user-facing call sites (`Text("`, `Button("`,
`Toggle("`, `Label("`, `Picker("`, `.navigationTitle("`, `.help("`,
`.accessibilityLabel("`, `.accessibilityHint("`, `.alert("`,
`.confirmationDialog("`). It runs in the pre-commit hook and in `make lint`,
both CI gates.

Since the #314 Phase 5 flip, the rule is enforced **module-wide**
(`Modules/UI/Sources/UI/.*\.swift`); the per-file allowlist that tracked the
migration is gone. Any new view file is covered automatically.

The rule is line-based and deliberately simple. It cannot see a literal passed
through a variable or built in a view model; those were converted by the
Phase 5 cross-cutting sweep and are protected by the `L10nTests`
source-convention tests, not by lint. Multi-argument format keys look up under
the non-positional form Foundation generates (`Failed to import %@: %@`) while
their catalog *values* use positional specifiers (`%1$@`, `%2$@`) so
translators can reorder arguments.

## Testing strategy

**SwiftPM does not compile `.xcstrings`. Only the Xcode build does.** Under
`swift test` / `make test-ui` the catalog is merely copied into the bundle, so
`String(localized:bundle:)` falls back to returning the key. Consequences:

- Do **not** write tests that assert runtime `String(localized:)` resolution;
  the result is build-system dependent. Validate the catalog *content* instead,
  as `L10nTests` does (parse the `.xcstrings` JSON, assert keys and plural
  variations). The catalog is the source of truth.
- Runtime correctness is confirmed by the Xcode build shipping
  `UI_UI.bundle/.../en.lproj/Localizable.stringsdict` inside the app.
- An Xcode build (`make test`) rewrites the catalog via auto-extraction; that
  churn is unrelated to most changes and can be reverted.

## Gotchas carried forward

- A bare `Text("…")` in this module never localizes. It must go through `L10n`.
- Keep English catalog values byte-identical to the old literals so default
  size snapshots do not drift.
- AppKit table cells (`TrackTableHelpers`, `SubsonicSongTableCells`, the AppKit
  parts of `NowPlayingStrip`) must use `L10n.string`; `LocalizedStringKey` does
  not apply there.
- Strings assembled from fragments (common in view-model toasts) cannot be
  translated word-by-word; restructure them into a single format key with
  arguments before converting.

## Pseudolocale (en-XA)

The catalog carries an `en-XA` pseudolocale: accented English expanded by
roughly 30% (`Could not play album.` becomes `Çóúĺđ ñóţ ƥĺáý áĺƀúḿ. one two`).
It is generated, not hand-maintained:

- `make pseudolocale` (runs `Scripts/gen-pseudolocale.py`) regenerates every
  `en-XA` value from the English copy. Re-run it after adding or changing
  catalog keys; the script is idempotent and rewrites the catalog in Xcode's
  canonical sorted form.
- `L10nTests` asserts every key has an `en-XA` variant, that lettered copy is
  at least ~30% longer than the English, and that format specifiers survive.
- **Manual check:** build the app, then launch it with the pseudolocale:
  `open build/Build/Products/Debug/Bocan.app --args -AppleLanguages '(en-XA)'`.
  Accented text everywhere proves copy resolves through the module catalog (a
  plain-English string is a missed conversion); clipped or truncated controls
  show where layouts cannot absorb ~30% expansion.
