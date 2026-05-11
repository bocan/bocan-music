# Accessibility Phase 3 — Reduce Transparency

> Prerequisites: Core app phases complete.
>
> Read `phases/_standards.md` first.

## Goal

Respect the macOS **Reduce Transparency** system preference (`System Settings →
Accessibility → Display → Reduce transparency`). Users with visual processing difficulties,
certain cognitive disabilities, or simply preferring high contrast rely on this. When it's
on, macOS removes vibrancy/blur from its own chrome — Bòcan must do the same for its custom
translucent surfaces, and must never convey meaning *only* through transparency.

## Non-goals

- Replacing all macOS-native blur (e.g. the menu bar, standard toolbar) — the OS handles
  those automatically.
- Dark mode redesign — that's Appearance settings.

## Outcome shape

```
Modules/UI/Sources/UI/Transport/
└── NowPlayingStrip.swift            # Frosted-glass background → solid

Modules/UI/Sources/UI/MiniPlayer/
├── MiniPlayerView.swift             # Vibrancy background → solid
└── MiniPlayerCompact.swift

Modules/UI/Sources/UI/Visualizer/
└── VisualizerView.swift             # Semi-transparent overlay on top of art → solid

Modules/UI/Sources/UI/Lyrics/
└── LyricsPane.swift                 # Gradient fade at edges → hard edge or solid

Modules/UI/Sources/UI/Theme/
└── Theme.swift  (or SemanticColors.swift)  # Add reduceTransparency-aware colour tokens
```

## Implementation plan

### 1. Read the environment value

```swift
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
```

Reactive; works in previews. Do not read `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` directly in views.

### 2. Add semantic colour helpers to Theme

Add two helpers so any view can get the right background without repeating the conditional:

```swift
extension Theme {
    /// Opaque alternative to a translucent/vibrancy surface.
    static func panelBackground(reduceTransparency: Bool) -> Color {
        reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.clear
    }

    static func overlayBackground(reduceTransparency: Bool, opacity: Double = 0.6) -> Color {
        reduceTransparency
            ? Color(nsColor: .windowBackgroundColor)
            : Color.black.opacity(opacity)
    }
}
```

### 3. Transport strip / now-playing background

If `NowPlayingStrip` uses `.background(.ultraThinMaterial)` or a custom blur:

```swift
.background(
    reduceTransparency
        ? AnyView(Color(nsColor: .windowBackgroundColor))
        : AnyView(Color.clear.background(.ultraThinMaterial))
)
```

Never use `AnyView` if you can avoid it — prefer a `@ViewBuilder` helper:

```swift
@ViewBuilder
private var stripBackground: some View {
    if reduceTransparency {
        Color(nsColor: .windowBackgroundColor)
    } else {
        Color.clear.background(.ultraThinMaterial)
    }
}
```

### 4. Mini-player window

The mini-player likely uses a `NSVisualEffectView` or `.background(.thickMaterial)` to
achieve its frosted-glass look. Gate it:

```swift
.background(
    reduceTransparency
        ? Color(nsColor: .controlBackgroundColor)
        : Color.clear.background(.thickMaterial)
)
```

If the mini-player's window itself is `NSWindow` with `styleMask` containing
`.fullSizeContentView` and a vibrancy effect view set as content, replace the effect view
with a plain `NSBox` (fill = `.windowBackground`) when the preference is on. Do this in the
`NSViewRepresentable` or `NSWindowDelegate`.

### 5. Visualiser overlay

If the visualiser renders bars/particles over a blurred artwork background:

```swift
// Artwork dim/blur layer
Color.black.opacity(reduceTransparency ? 0.85 : 0.45)
```

The artwork itself should still be visible (legible context), but the overlay must be opaque
enough to maintain text contrast.

### 6. Lyrics pane gradient fade

A common pattern is to fade lyrics text at the top and bottom of the scroll view using a
gradient mask. This communicates "there is more content here" — but if the user can't see
the gradient clearly, they may not know to scroll. When `reduceTransparency` is on:

- Remove the gradient mask entirely (hard edge at the scroll view boundary is fine).
- Optionally add a visible scroll indicator or a faint separator line.

```swift
.mask(
    reduceTransparency
        ? AnyView(Rectangle())
        : AnyView(LinearGradient(/* ... fade at top and bottom */))
)
```

### 7. Never convey meaning through opacity alone

Audit every place opacity is used as the *only* signal:

- **Disabled state**: a button at 30% opacity to indicate it's disabled. Fine — but also
  ensure `.disabled(true)` is set so VoiceOver announces "dimmed".
- **Selected state**: never select-by-opacity-only; always use a background fill or border
  too.
- **Error state**: never indicate error only with a red tint at low opacity; pair with an
  icon or text.

### 8. `.foregroundStyle(.secondary)` captions

`Color.secondary` on macOS is approximately 40% opacity of the primary label colour. On a
vibrancy background this is fine. On a solid background it may become too light. Test
caption text contrast in both modes (see Phase 4 — Colour Contrast for exact ratios).

## Verification steps

1. Enable `System Settings → Accessibility → Display → Reduce transparency`.
2. Inspect the mini-player — background should be a solid system colour, not frosted glass.
3. Open the Visualiser — bars appear over a clearly visible, non-blurred background.
4. Open lyrics — no gradient fade, hard edge at scroll view boundary.
5. Check all `.secondary` caption text is still legible (no disappearing text).
6. Disable the preference — frosted glass and gradients return.
7. Run Accessibility Inspector → `Element` tab on the mini-player window; confirm no
   element reports its only distinguishing visual attribute as opacity.

## Tests

Snapshot tests with `\.accessibilityReduceTransparency = true` in the environment for:
- `MiniPlayerView`
- `NowPlayingStrip`
- `LyricsPane`
- `VisualizerView`

Compare against the standard (non-reduced) snapshots to confirm backgrounds changed.

## Commit message

```
feat(ui): respect Reduce Transparency — solid backgrounds for mini-player, strip, lyrics
```
