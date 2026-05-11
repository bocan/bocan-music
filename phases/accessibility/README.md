# Accessibility Phases — Overview

> Read `phases/_standards.md` before starting any phase here.

These phases address the six main macOS accessibility considerations for Bòcan V1.
They are independent of each other and can be done in any order, but the priority
order below is recommended based on user impact.

## Phases

| File | Topic | Priority | Why |
|------|--------|----------|-----|
| [phase1-voiceover.md](phase1-voiceover.md) | VoiceOver | 🔴 High | Largest impact for blind/low-vision users; broken VoiceOver is the most-reported accessibility issue in music apps |
| [phase2-reduce-motion.md](phase2-reduce-motion.md) | Reduce Motion | 🔴 High | Vestibular disorders are common; the Visualiser is a significant offender |
| [phase3-reduce-transparency.md](phase3-reduce-transparency.md) | Reduce Transparency | 🟡 Medium | Low effort; many views already use system materials |
| [phase4-colour-contrast.md](phase4-colour-contrast.md) | Colour Contrast | 🟡 Medium | Tertiary text and accent-on-selected-row are known risk areas |
| [phase5-keyboard-focus.md](phase5-keyboard-focus.md) | Keyboard Focus | 🟡 Medium | You already have keyboard shortcuts; full Tab navigation fills in the gaps |
| [phase6-dynamic-type.md](phase6-dynamic-type.md) | Dynamic Type | 🟢 Lower | macOS users less frequently use this than iOS; but replacing hardcoded sizes is mechanical |

## What's already done

- **Keyboard shortcuts**: Most playback actions have `⌘`-key shortcuts.
- **Tooltips (`.help()`)**: All Settings panes, all icon-only transport buttons, major
  browsing controls.
- **`accessibilityLabel`**: Icon buttons, destructive actions, cancel buttons,
  progress indicators.
- **`accessibilityHint`**: Key interactive elements in DSP, Diagnostics.
- **`Form { }.formStyle(.grouped)`**: Settings views use this pattern, which gives
  VoiceOver correct label/control association automatically.

## What's not yet done (as of V1 scope)

- VoiceOver row labels on `NSTableView` (Phase 1)
- Live track-change announcements (Phase 1)
- Reduce Motion gates on Visualiser animations (Phase 2)
- Reduce Transparency on mini-player and lyrics pane (Phase 3)
- WCAG AA contrast audit (Phase 4)
- Full Tab-key navigation graph including album grid (Phase 5)
- `@ScaledMetric` / semantic fonts throughout (Phase 6)

## References

- [Apple Human Interface Guidelines — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [WCAG 2.1 Quick Reference](https://www.w3.org/WAI/WCAG21/quickref/)
- [NSAccessibility Programming Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Accessibility/cocoaAXIntro/cocoaAXintro.html)
- [SwiftUI Accessibility Modifiers](https://developer.apple.com/documentation/swiftui/view-accessibility)
