# Accessibility Phase 2 — Reduce Motion

> Prerequisites: Core app phases complete. Phase accessibility/phase1-voiceover.md recommended first.
>
> Read `phases/_standards.md` first.

## Goal

Respect the macOS **Reduce Motion** system preference (`System Settings → Accessibility →
Display → Reduce motion`). Users with vestibular disorders, migraines, or motion sensitivity
can have serious physical reactions to animated transitions, particle effects, and
parallax. Every animation in Bòcan must either stop or simplify to a static/fade
alternative when this is on.

## Non-goals

- Disabling all animation unconditionally — that would hurt usability for everyone else.
- Animating the audio waveform/spectrum data itself — data updates are fine, it's
  *decorative motion* (zoom, bounce, particle spray) that must stop.

## Outcome shape

No new files. Changes are spread across existing animation and visualiser code.

```
Modules/UI/Sources/UI/Visualizer/
└── VisualizerView.swift             # Freeze or simplify when reduceMotion is on

Modules/UI/Sources/UI/Transport/
└── NowPlayingStrip.swift            # Track-change crossfade animation

Modules/UI/Sources/UI/Browse/
└── AlbumsGridView.swift             # Cover art hover scale animation

Modules/UI/Sources/UI/AppRoot/
└── RootView.swift                   # Any NavigationSplitView transition animations
```

## Implementation plan

### 1. Read the environment value everywhere you animate

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
```

This is the single source of truth. Do **not** read `UserDefaults` directly or query
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` — the environment value is
reactive and works in SwiftUI previews too.

### 2. Visualiser — biggest offender

The visualiser likely has the most dramatic motion (bar animations, particle spray, waveform
morphing). When `reduceMotion` is on:

- **Bar/spectrum visualiser**: Remove the `withAnimation` block; update bar heights
  instantly (no spring, no ease).
- **Particle/nebula visualiser**: Freeze particle positions; continue updating colour based
  on the audio signal (static colour response is fine, movement is the problem).
- **Waveform oscilloscope**: This is data-driven and real-time — acceptable as-is since
  it reflects live audio. Keep it.

Pattern:

```swift
private func updateBars(_ newValues: [Float]) {
    if reduceMotion {
        barHeights = newValues.map(Double.init)
    } else {
        withAnimation(.spring(response: 0.15, dampingFraction: 0.7)) {
            barHeights = newValues.map(Double.init)
        }
    }
}
```

### 3. Now-playing strip — track change transition

If the artwork or track title crossfades or slides on track change, replace with an
instant swap or a simple opacity transition (fades are acceptable under Reduce Motion —
the issue is spatial movement, not opacity):

```swift
.transition(reduceMotion ? .opacity : .asymmetric(
    insertion: .move(edge: .trailing).combined(with: .opacity),
    removal: .move(edge: .leading).combined(with: .opacity)
))
```

### 4. Album grid — hover scale

If any album artwork scales up on hover (`.scaleEffect` in an `.onHover` handler), gate it:

```swift
.scaleEffect(isHovered && !reduceMotion ? 1.04 : 1.0)
.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
```

### 5. Navigation transitions

SwiftUI's `NavigationSplitView` uses a push/pop animation. On macOS this is subtle and
generally fine. If you have any custom `.transition()` modifiers on navigation destination
views, gate them with `reduceMotion`.

### 6. Loading / progress animations

`ProgressView()` spinner is a system control — it respects Reduce Motion automatically.
Any custom loading shimmer or skeleton animation you've built should stop when `reduceMotion`
is on: replace with a static tinted rectangle.

### 7. Drag-and-drop visual feedback

If a track is dragged into a playlist and triggers an animated insertion, gate the spring
animation:

```swift
withAnimation(reduceMotion ? nil : .spring()) {
    items.insert(dropped, at: index)
}
```

## Verification steps

1. Go to `System Settings → Accessibility → Display → Reduce motion` and enable it.
2. Open the Visualiser — bars should update values without bouncing or easing.
3. Skip to the next track — artwork/title should swap instantly or fade, not slide.
4. Hover over album artwork — no scale animation.
5. Navigate into an artist or album — no slide-in push animation on destination content.
6. Drag a track to a playlist — insertion is instant.
7. Disable Reduce Motion — all animations return normally.

## Tests

Snapshot tests: render `VisualizerView` and `NowPlayingStrip` with
`\.accessibilityReduceMotion` set to `true` in the environment. Confirm no `withAnimation`
block produces visual delta between frames in the snapshot.

A simpler unit-level test: assert that when `reduceMotion == true`, `updateBars()` sets
`barHeights` synchronously (no animation transaction is active). Use
`Transaction.current.animation == nil` as the assertion.

```swift
@Test func barsUpdateInstantlyWhenReduceMotionOn() {
    var sut = VisualizerBarModel(reduceMotion: true)
    sut.update([0.5, 0.8, 0.3])
    #expect(sut.barHeights == [0.5, 0.8, 0.3])
}
```

## Commit message

```
feat(ui): respect Reduce Motion — freeze visualiser, instant track transitions
```
