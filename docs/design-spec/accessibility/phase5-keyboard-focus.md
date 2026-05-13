# Accessibility Phase 5 — Keyboard Focus & Navigation

> Prerequisites: Core app phases complete. Phase accessibility/phase1-voiceover.md recommended.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Every interactive element in Bòcan is reachable and operable via keyboard alone — no mouse
required. Tab moves focus logically through the window. Space / Return activate focused
controls. Arrow keys navigate lists and grids. No focus traps. Custom controls that are
not natively focusable are made focusable.

This goes beyond keyboard shortcuts (which jump to specific actions) to cover the full
Tab-key navigation graph and focus ring visibility.

## Non-goals

- Custom keyboard shortcut configuration UI — that's a separate feature.
- Controller / game pad support.

## Outcome shape

No new files. Targeted modifier additions to existing views.

```
Modules/UI/Sources/UI/Browse/
├── AlbumsGridView.swift             # Grid cells become keyboard-focusable
└── ArtistsView.swift                # Artist list keyboard navigation

Modules/UI/Sources/UI/Transport/
└── NowPlayingStrip.swift            # Transport button focus order

Modules/UI/Sources/UI/DSP/
└── EQView.swift                     # Band sliders focusable, arrow-key adjust

Modules/UI/Sources/UI/AppRoot/
└── RootView.swift                   # Focus scope and initial focus
```

## Implementation plan

### 1. Verify the Tab-key navigation graph

Work through the main window with Tab and note where focus goes. The desired order is:

1. Sidebar (artist/album/playlist source list)
2. Content pane (track table or album grid)
3. Transport strip (scrubber → volume → prev → play/pause → next → shuffle → repeat)
4. Any open panel (lyrics, visualiser controls)

Use `@FocusState` in root views to control initial focus, and `.focusSection()` to group
related controls.

### 2. Transport strip focus

Each icon button should be a standard SwiftUI `Button` (they are natively focusable). If
any transport control is a custom `NSButton` or a gesture-only view, replace or wrap it:

```swift
Button(action: vm.playPause) {
    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
}
.keyboardShortcut(.space, modifiers: [])
.accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
```

The scrubber (`Slider`) is natively focusable and responds to arrow keys — verify it does.

### 3. NSTableView — already good

`NSTableView` handles arrow-key navigation natively. Ensure the track table's `NSView` host
is in the Tab order by checking `tableView.refusesFirstResponder == false`.

### 4. Album grid — SwiftUI `LazyVGrid`

`LazyVGrid` cells are not focusable by default. Add:

```swift
// On each album cell Button:
.focusable()
.onKeyPress(.return) { openAlbum(album); return .handled }
.onKeyPress(.space)  { openAlbum(album); return .handled }
```

Or, if cells are not `Button`s, wrap them:

```swift
Button { openAlbum(album) } label: { albumCellContent(album) }
    .buttonStyle(.plain)
    .accessibilityLabel(album.title)
```

Plain `Button` style is invisible (no default ring) so add a visible focus ring manually
if the design requires it, or use `.focusEffectDisabled(false)`.

### 5. Arrow-key navigation within the album grid

SwiftUI doesn't automatically make `LazyVGrid` respond to arrow keys. Use `@FocusState`
with a tagged value approach:

```swift
@FocusState private var focusedAlbumID: Int64?

ForEach(albums) { album in
    albumCell(album)
        .focused($focusedAlbumID, equals: album.id)
}
.onKeyPress(.leftArrow)  { moveFocus(by: -1); return .handled }
.onKeyPress(.rightArrow) { moveFocus(by: +1); return .handled }
.onKeyPress(.upArrow)    { moveFocus(by: -columnCount); return .handled }
.onKeyPress(.downArrow)  { moveFocus(by: +columnCount); return .handled }
```

### 6. EQ band sliders

Vertical sliders (`EQBandSlider`) should already be focusable as `Slider` views. Verify
that arrow keys adjust the value. Add step hints:

```swift
Slider(value: $gain, in: -12...12, step: 0.5)
    .accessibilityLabel("\(band.frequency) Hz")
    .accessibilityValue(String(format: "%+.1f dB", gain))
    // arrow keys adjust by step automatically for Slider
```

### 7. Context menus via keyboard

Right-click context menus must be triggerable by keyboard. On macOS, `Control + Return` or
the Application key should open the context menu on the focused item. SwiftUI `.contextMenu`
supports this automatically. Verify it works on:

- Track table rows (select row, hit application key)
- Album grid cells
- Playlist items in sidebar

### 8. Modal sheets — focus management

When a sheet opens (tag editor, Add to Playlist, confirmation dialog), focus must move
inside the sheet automatically. SwiftUI handles this. Verify no custom `NSPanel` or
programmatically-presented view fails to take focus.

When the sheet closes, focus must return to the element that opened it. Use
`@FocusState` with a Boolean to restore focus after sheet dismissal:

```swift
@FocusState private var triggerButtonFocused: Bool

Button("Edit") { showSheet = true }
    .focused($triggerButtonFocused)
    .onChange(of: showSheet) { _, open in
        if !open { triggerButtonFocused = true }
    }
```

### 9. No focus traps

Tab through the entire app and confirm:
- Focus never gets stuck in a non-interactive element.
- Escape closes modals and returns focus (standard macOS behaviour — don't break it).
- Tab in the last focusable element cycles back to the first (standard).

### 10. Focus ring visibility

Ensure `.focusEffectDisabled(false)` is not accidentally called anywhere. The system
focus ring must be visible on every focusable element. If the design suppresses it for
aesthetic reasons, add a custom ring using `.overlay` instead:

```swift
.overlay(
    RoundedRectangle(cornerRadius: 6)
        .stroke(Color.accentColor, lineWidth: isFocused ? 2 : 0)
)
```

## Verification steps

1. Open Bòcan with mouse disconnected (or ignore it).
2. Press Tab repeatedly; confirm all interactive elements receive focus in logical order.
3. In the track list, use arrow keys to move between rows; Return plays the track.
4. In the album grid, Tab to the grid, then arrow-key through cells.
5. Focus a transport button, press Space — it activates.
6. Focus a track row, press the application key or Control+Return — context menu appears.
7. Tab into the EQ sliders; arrow keys change the value; it's announced by VoiceOver.
8. Open a sheet (e.g. tag editor); Tab stays inside the sheet; Escape closes it; focus
   returns to the triggering element.
9. No element is unreachable by Tab alone.

## Tests

```swift
@Test func albumGridCellIsButtonForFocusability() throws {
    // Confirm AlbumCell wraps content in Button (natively focusable)
    let view = AlbumCell(album: .fixture())
    let mirror = Mirror(reflecting: view.body)
    #expect(mirror.description.contains("Button"))
}
```

More meaningfully: integration tests using `XCUIApplication` in the UI test target:

```swift
func testTabNavigationReachesTransportStrip() {
    let app = XCUIApplication()
    app.launch()
    // Tab through elements, assert play button gains focus
    app.typeKey("\t", modifierFlags: [])
    // ... repeat until transport is focused
    XCTAssert(app.buttons["Play"].hasFocus)
}
```

## Commit message

```
feat(ui): full keyboard focus navigation — album grid, transport strip, EQ sliders, sheets
```
