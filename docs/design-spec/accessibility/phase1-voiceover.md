# Accessibility Phase 1 — VoiceOver

> Prerequisites: Core app phases complete (Phases 0–13 recommended).
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Make Bòcan Music fully navigable and usable by a blind or low-vision user running VoiceOver
(`System Settings → Accessibility → VoiceOver`, or `⌘F5` to toggle). Every interactive
element must have a meaningful spoken description. Navigation must not trap focus.

## Non-goals

- tvOS / iOS VoiceOver — macOS only.
- Braille display output — nice to have but not required for V1.
- Full Accessibility Inspector audit of third-party libraries (GRDB, FFmpeg wrappers).

## Outcome shape

No new files. All changes are modifier additions to existing SwiftUI views and the
`NSTableView` coordinator.

```
Modules/UI/Sources/UI/Browse/
├── TrackTable.swift                 # NSTableView row accessibility
├── TrackTableCoordinator.swift      # tableView(_:accessibilityLabelForRow:) override
├── AlbumsGridView.swift             # Album cell combined label
└── ArtistsView.swift                # Artist cell combined label

Modules/UI/Sources/UI/Transport/
└── NowPlayingStrip.swift            # Live announcement on track change

Modules/UI/Sources/UI/DSP/
└── EQView.swift                     # Band slider accessibilityValue formatting
```

## Implementation plan

### 1. Track table (NSTableView) — row-level VoiceOver label

VoiceOver reads each `NSTableView` row as a sequence of column values by default. This is
verbose and confusing. Override it to speak a single sentence per row.

In `TrackTableCoordinator`, implement:

```swift
func tableView(_ tableView: NSTableView, accessibilityLabelForRow row: Int) -> String? {
    let r = rows[row]
    let duration = Formatters.duration(r.duration)
    return "\(r.title), \(r.artist), \(r.album), \(duration)"
}
```

Also set `tableView.rowHeight` never below 20 pt (already satisfied) and ensure
`tableView.usesAlternatingRowBackgroundColors` remains true — VoiceOver users rely on the
row count cursor.

### 2. Album grid cells — combined label

In `AlbumsGridView` and `ArtistsView`, every album `VStack` cell should use:

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel("\(album.title), \(album.artist ?? ""), \(album.year.map(String.init) ?? "")")
.accessibilityHint("Double-tap to open album")
```

Without `.combine` VoiceOver reads artwork placeholder + title + subtitle as three separate
stops.

### 3. Artist cells

Same pattern: `.accessibilityElement(children: .combine)` on the artist row/cell, label is
the artist name.

### 4. Now-playing strip — live announcement on track change

When the playing track changes, post an announcement so VoiceOver users know what's playing
without navigating to the transport area.

```swift
.onChange(of: vm.currentTrack) { _, track in
    guard let track else { return }
    let msg = "\(track.title) by \(track.artist ?? "Unknown")"
    NSAccessibility.post(element: NSApp, notification: .announcementRequested,
                         userInfo: [.announcement: msg, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
}
```

Apply to `NowPlayingStrip` or its parent view. Use `.medium` priority so it doesn't
interrupt a user mid-sentence in another element.

The now-playing label itself should also carry `.accessibilityAddTraits(.updatesFrequently)`
so VoiceOver polls it automatically.

### 5. EQ band sliders — accessibilityValue

The vertical `EQBandSlider` currently has an `accessibilityLabel("N Hz")`. Add a formatted
`accessibilityValue`:

```swift
.accessibilityValue(String(format: "%+.1f dB", value))
```

So VoiceOver reads *"80 Hz, minus 3 decibels"* rather than just *"80 Hz, −0.3"*.

### 6. Playbar transport buttons

Every icon-only button (play/pause, previous, next, shuffle, repeat) must have an
`accessibilityLabel`. Verify each one:

| Button | Required label |
|--------|---------------|
| Play / Pause | `"Play"` / `"Pause"` (dynamic) |
| Previous | `"Previous track"` |
| Next | `"Next track"` |
| Shuffle | `"Shuffle: on"` / `"Shuffle: off"` (dynamic) |
| Repeat | `"Repeat: off"` / `"Repeat: one"` / `"Repeat: all"` (dynamic) |
| Volume | `"Volume, N percent"` |

Use `.accessibilityValue` for state (on/off) and `.accessibilityLabel` for the control
name, so VoiceOver reads *"Shuffle, on, button"*.

### 7. Playbar scrubber

The seek slider needs:

```swift
.accessibilityLabel("Playback position")
.accessibilityValue(Formatters.duration(elapsed) + " of " + Formatters.duration(total))
```

### 8. Context menus

VoiceOver can open context menus via `VO + Shift + M`. Ensure every context menu item has a
descriptive title (no bare "…" strings without context).

### 9. Modal sheets and dialogs

Every `sheet` and `confirmationDialog` that can open from a context menu or toolbar button
must move VoiceOver focus inside the sheet automatically. SwiftUI does this by default;
verify it's not broken by any custom `NSPanel` usage.

## Verification steps

1. Enable VoiceOver (`⌘F5`).
2. Tab through the sidebar, track list, transport strip, and settings without getting stuck.
3. Arrow-key through 10 track rows; each should announce *"Title, Artist, Album, Duration"*.
4. Change track via Next button; hear the now-playing announcement.
5. Open an album; all cells should each be a single VoiceOver stop.
6. Open DSP & EQ; focus each band slider and confirm it reads *"N Hz, +/− X dB"*.
7. Open a context menu on a track via `VO + Shift + M`; all items readable.
8. Run Accessibility Inspector (Xcode → Open Developer Tool → Accessibility Inspector) and
   audit the main window for warnings.

## Tests

Add snapshot tests in the `UI` package with VoiceOver traits checked:

```swift
@Test func trackRowAccessibilityLabel() async throws {
    let row = TrackRow(/* ... */)
    let label = coordinator.tableView(tableView, accessibilityLabelForRow: 0)
    #expect(label == "In My Life, The Beatles, Rubber Soul, 2:47")
}
```

Unit-test the label formatting function in isolation; the NSTableView delegate method
itself is integration-tested via the existing coordinator tests.

## Commit message

```
feat(ui): VoiceOver support — row labels, live track announcements, combined album cells
```
