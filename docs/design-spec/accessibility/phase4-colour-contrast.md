# Accessibility Phase 4 — Colour Contrast

> Prerequisites: Core app phases complete.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Ensure every text element in Bòcan meets **WCAG 2.1 AA** minimum contrast ratios against
its background:

- Normal text (< 18pt / < 14pt bold): **4.5 : 1**
- Large text (≥ 18pt / ≥ 14pt bold): **3 : 1**
- UI components and graphical objects (icons, chart bars): **3 : 1**

Both light mode and dark mode must pass. The accent colour palette must also maintain
sufficient contrast when used as a button background with white/black text on top.

## Non-goals

- WCAG AAA (7 : 1) — that's a stretch goal, not required for V1.
- Contrast in third-party components (NSTableView alternating rows, system pickers).
- Dynamically-generated artwork colours used as backgrounds (album art dominant colour
  behind text is a separate, hard problem — flag it but don't solve it now).

## Outcome shape

No new feature files. Changes are to `Theme.swift` / `SemanticColors.swift` colour
token values, and potentially individual view overrides.

```
Modules/UI/Sources/UI/Theme/
├── Theme.swift  (or SemanticColors.swift)   # Token value adjustments
└── ContrastAudit.swift                       # DEBUG-only utility that dumps contrast ratios
```

## Implementation plan

### 1. Audit tool

Before changing anything, measure what you have. Build a debug utility:

```swift
#if DEBUG
import SwiftUI

struct ContrastAuditView: View {
    var body: some View {
        Form {
            auditRow("textPrimary on bgPrimary",
                     fg: Color.textPrimary, bg: Color.bgPrimary)
            auditRow("textSecondary on bgPrimary",
                     fg: Color.textSecondary, bg: Color.bgPrimary)
            auditRow("textTertiary on bgPrimary",
                     fg: Color.textTertiary, bg: Color.bgPrimary)
            auditRow("textTertiary on bgSecondary",
                     fg: Color.textTertiary, bg: Color.bgSecondary)
            // Add all combinations you care about
        }
    }

    private func auditRow(_ name: String, fg: Color, bg: Color) -> some View {
        let ratio = contrastRatio(fg, bg)
        return LabeledContent(name) {
            Text(String(format: "%.2f : 1 %@", ratio, ratio >= 4.5 ? "✓" : "✗ FAIL"))
                .foregroundStyle(ratio >= 4.5 ? .green : .red)
        }
    }
}
#endif
```

Implement `contrastRatio(_:_:)` using the WCAG relative luminance formula:

```swift
func relativeLuminance(_ c: Color) -> Double {
    // Resolve to NSColor in the correct colour space
    let ns = NSColor(c).usingColorSpace(.displayP3) ?? NSColor(c)
    func linearise(_ v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    let r = linearise(Double(ns.redComponent))
    let g = linearise(Double(ns.greenComponent))
    let b = linearise(Double(ns.blueComponent))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

func contrastRatio(_ fg: Color, _ bg: Color) -> Double {
    let l1 = relativeLuminance(fg)
    let l2 = relativeLuminance(bg)
    let lighter = max(l1, l2)
    let darker  = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)
}
```

Add a hidden Settings entry (Diagnostics pane, or `#if DEBUG` menu item) to open
`ContrastAuditView`.

### 2. Likely problem areas

Based on common patterns in music players using semantic colours:

| Element | Risk | Why |
|---------|------|-----|
| `textTertiary` (year, subtitle, duration) | High | Often ~40% opacity or a light grey |
| Accent colour as button bg + white text | Medium | Accent may be very light (yellow, green) |
| `Color.secondary` captions in Settings | Medium | Approximately 40% opacity |
| Track title on selected (accent) row | High | White on accent colour |
| Placeholder artwork gradient text | High | Light text on colourful gradient |

### 3. Fix token values

For any failing pair, adjust the token in `Theme.swift`:

**Option A** — Darken/lighten the token colour itself:
```swift
// Before
static let textTertiary = Color(nsColor: .tertiaryLabelColor)
// After — use a slightly stronger system label if tertiary fails
static let textTertiary = Color(nsColor: .secondaryLabelColor)
```

**Option B** — Use opacity relative to background instead of absolute:
```swift
// Instead of 40% black (which fails on a dark bg)
// use a semantic system colour that automatically adapts
Color(nsColor: .secondaryLabelColor)  // adapts to light/dark automatically
```

Prefer system semantic colours (`NSColor.labelColor`, `.secondaryLabelColor`,
`.tertiaryLabelColor`, `.quaternaryLabelColor`) over hardcoded hex values — they have
been tuned by Apple for contrast.

### 4. Selected-row text contrast

When a track row is selected, the background becomes the accent colour. The row text colour
must remain readable. NSTableView handles this automatically for its own cell rendering, but
custom SwiftUI cells overlaid on the table may not. If you draw text with `Color.textPrimary`
on a selected row, ensure `.textPrimary` resolves to white (or very dark) on that background.

Test by selecting a row with each accent colour option enabled.

### 5. Accent palette

In `AppearanceSettingsView`, users can choose an accent colour. The palette in
`AccentPaletteView` must only offer colours that achieve ≥ 3 : 1 against both white and
the button's label colour. For accent colours that are inherently low-contrast (pastel
yellow, pale mint), either:

- Remove them from the palette, or
- Pair them with a dark label colour instead of white.

Document which rule each accent uses in a code comment.

### 6. Increase Contrast preference

Some users go further and enable `System Settings → Accessibility → Display → Increase
contrast`. macOS darkens borders and increases contrast automatically. Check that Bòcan
doesn't override any system border or separator that the OS would otherwise strengthen.
Use `Color(nsColor: .separatorColor)` for dividers, not a hardcoded grey.

```swift
@Environment(\.accessibilityIncreaseContrast) private var increaseContrast
```

You likely don't need to do anything extra if you use semantic system colours — but audit
it with the preference on.

## Verification steps

1. Open ContrastAuditView (Diagnostics pane or debug menu) in light mode.
   - All entries should show ✓ at ≥ 4.5 : 1 for normal text.
2. Switch to dark mode and re-check.
3. Enable each accent colour; select a track row; confirm row text is legible.
4. Enable `Increase Contrast`; check separators and borders become more visible (not less).
5. Use the Accessibility Inspector colour contrast calculator on the main window.
6. Check album subtitle/caption text in both light and dark in the track table.

## Tests

```swift
@Test func textPrimaryOnBgPrimaryMeetsWCAG_AA() {
    let ratio = contrastRatio(.textPrimary, .bgPrimary)
    #expect(ratio >= 4.5, "Expected ≥ 4.5, got \(ratio)")
}

@Test func textTertiaryOnBgPrimaryMeetsWCAG_AA() {
    let ratio = contrastRatio(.textTertiary, .bgPrimary)
    #expect(ratio >= 4.5)
}

// Run these in both light and dark by injecting NSAppearance
```

Put these in a `ContrastTests.swift` in the `UI` package tests.

## Commit message

```
feat(ui): WCAG AA colour contrast audit and token adjustments
```
