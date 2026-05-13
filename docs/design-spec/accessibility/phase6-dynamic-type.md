# Accessibility Phase 6 — Dynamic Type

> Prerequisites: Core app phases complete.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Bòcan's text scales correctly when a user sets a larger font size in
`System Settings → Accessibility → Display → Text size` (or via the Accessibility
shortcut). No text truncates, overlaps, or disappears. Layouts reflow gracefully at
larger sizes. Hard-coded point sizes are replaced with relative semantic styles.

macOS Dynamic Type is less pervasive than iOS — many users who need larger text set it at
the OS level and expect *all* apps to respect it. The primary mechanism is using
`NSFont.preferredFont(forTextStyle:)` / SwiftUI `.font(.body)` etc., which scale
automatically.

## Non-goals

- Full iOS-style font-size slider in Bòcan's own Settings — the OS setting is the right place.
- Supporting sizes above the system maximum — rely on the system maximum.
- Reflowing the `NSTableView` track list to multi-line rows — single-line rows that
  truncate at very large sizes are acceptable as long as the tooltip/VoiceOver reads the
  full text.

## Outcome shape

No new files. Changes are mechanical — replace hardcoded `Font.system(size:)` with
semantic styles, and audit `Typography.*` constants.

```
Modules/UI/Sources/UI/Theme/
└── Typography.swift                 # Audit and fix hardcoded sizes

Modules/UI/Sources/UI/Browse/
├── TrackTable+Helpers.swift         # NSTableView cell font
└── AlbumsGridView.swift             # Title/subtitle fonts

Modules/UI/Sources/UI/Transport/
└── NowPlayingStrip.swift            # Track title / artist fonts

Modules/UI/Sources/UI/Settings/
└── (all)                            # Any hardcoded caption sizes
```

## Implementation plan

### 1. Audit `Typography.swift` for hardcoded sizes

Open `Modules/UI/Sources/UI/Theme/Typography.swift`. Any line using
`Font.system(size: N)` must be replaced with a semantic equivalent:

| Hardcoded | Replacement | Notes |
|-----------|-------------|-------|
| `Font.system(size: 13)` | `.body` | Default body text |
| `Font.system(size: 11)` | `.caption` | Captions, subtitles |
| `Font.system(size: 10)` | `.caption2` | Very small labels |
| `Font.system(size: 15, weight: .semibold)` | `.headline` | Section headers |
| `Font.system(size: 20, weight: .bold)` | `.title3` | Album/artist hero titles |
| `.monospacedDigit()` | Chain onto the semantic style | Preserves digit alignment |

If a specific size is genuinely required (e.g. the EQ band labels at the bottom of a
fixed-height column), use `.font(.system(size: N, design: .default).leading(.tight))`
with a comment explaining why it's fixed, and accept that it won't scale. Document every
exception.

### 2. NSTableView cell fonts

The `NSTableView` cells use `NSFont` directly. Ensure they use:

```swift
// Instead of:
NSFont.systemFont(ofSize: 13)
// Use:
NSFont.preferredFont(forTextStyle: .body)
// For caption cells:
NSFont.preferredFont(forTextStyle: .caption1)
```

`NSFont.preferredFont(forTextStyle:)` scales with the system text size setting.

Register for `NSFont.fontSizeChangedNotification` if you cache the font:

```swift
NotificationCenter.default.addObserver(
    forName: NSFont.didChangeNotification,
    object: nil, queue: .main
) { [weak tableView] _ in
    tableView?.reloadData()
}
```

### 3. NowPlayingStrip

The currently-playing track title and artist name in the transport area should use
`.body` and `.caption` (or `.footnote`) respectively. If they're truncating at large sizes,
allow them to grow: remove any fixed `frame(height:)` on the text container and use
`.lineLimit(1)` with `.truncationMode(.middle)` so at least both ends of a long title
are visible.

### 4. Album grid

Album title and subtitle in `AlbumsGridView` and `ArtistsView`:
- Title: `.font(Typography.subheadline)` → ensure this resolves to `.subheadline` not
  `Font.system(size: 12)`.
- Subtitle: `.font(Typography.caption)` → `.caption`.

At very large text sizes, the album artwork cell will overflow its grid column. Allow the
grid `minimum` to scale:

```swift
// Instead of a fixed minimum:
let albumColumns = [GridItem(.adaptive(minimum: Theme.albumGridMinWidth))]
// Theme.albumGridMinWidth can be a @ScaledMetric:
@ScaledMetric(relativeTo: .body) private var albumGridMinWidth = 120.0
```

`@ScaledMetric` scales a value proportionally to the current text size.

### 5. Settings and DSP views

Scan all Settings views for `.font(.caption)` used as a help/description text below a
control. These are already semantic — just verify none have been overridden with
`Font.system(size: 11)`.

### 6. Tooltips / help text

Tooltip text (`.help(...)`) is rendered by macOS and always uses the system font at the
system size. No changes needed there.

### 7. Minimum touch / click targets

At larger text sizes, if buttons grow taller, their hit area grows with them (good). But
small icon buttons (playbar controls) have fixed sizes. Ensure they meet the minimum
recommended click target of 44×44 pt even at the default text size. Use
`.frame(minWidth: 44, minHeight: 44)` with `contentShape(Rectangle())` if the visual
size is smaller.

### 8. `@ScaledMetric` for spacing

Vertical spacing between elements can also be made to scale:

```swift
@ScaledMetric(relativeTo: .body) private var rowSpacing = 4.0
```

This is optional polish — fixed spacing that works at default size is acceptable. Use
`@ScaledMetric` only where cramped spacing at large text sizes is visible.

## Verification steps

1. `System Settings → Accessibility → Display → Text size` — set to maximum.
2. Launch Bòcan.
3. Track table: text is larger; rows may clip but don't overlap.
4. Album grid: grid columns adapt (more wrapping, fewer columns).
5. NowPlayingStrip: track title is larger; truncates gracefully with ellipsis.
6. Settings: caption help text below controls is readable and not clipped.
7. All buttons remain clickable (no tiny targets).
8. Return text size to default — everything returns to normal.

## Tests

```swift
@Test func typographyUsesSemanticStyles() throws {
    // Ensure Typography constants map to semantic Font values
    // This is a code convention check, not a visual one.
    // A lightweight approach: grep the file in a test.
    let source = try String(contentsOf: URL(filePath: "Modules/UI/Sources/UI/Theme/Typography.swift"))
    #expect(!source.contains("Font.system(size:"),
            "Typography should not use hardcoded font sizes")
}
```

Snapshot tests at two text sizes using `sizeCategory` environment:

```swift
assertSnapshot(
    of: AlbumCell(album: .fixture()),
    as: .image(layout: .fixed(width: 160, height: 200)),
    named: "album-cell-default-text"
)
// Then with large text:
// (inject via environment .sizeCategory = .accessibilityLarge)
```

## Commit message

```
feat(ui): Dynamic Type support — semantic fonts, @ScaledMetric grid, NSTableView cell fonts
```
