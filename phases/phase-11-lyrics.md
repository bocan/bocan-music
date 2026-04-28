# Phase 11 — Lyrics

> Prerequisites: Phases 0–10 complete. `LRCParser` exists in `Metadata` (Phase 3). `lyrics` table exists.
>
> Read `phases/_standards.md` first.

## Goal

Show lyrics for the current track. Support embedded unsynced lyrics, embedded synced (SYLT), sidecar `.lrc` files, and user-pasted text. Auto-scroll synced lyrics in time with playback. Allow editing and saving (embedded in file, optional). Optional opt-in fetch from LRClib for tracks with nothing.

## Non-goals

- Commercial lyrics APIs with hostile T&Cs (Genius, Musixmatch) — explicitly excluded.
- Karaoke-style word-level highlighting within a line — stretch; basic per-line is the v1 target.
- Translations.

## Outcome shape

```
Modules/Metadata/Sources/Metadata/Lyrics/
└── (LRCParser.swift already exists; flesh out further)

Modules/Library/Sources/Library/Lyrics/
├── LyricsService.swift                # CRUD + fetch coordinator
├── LRClibClient.swift                 # Opt-in fetcher
└── LyricsSources.swift                # Priority resolver

Modules/UI/Sources/UI/Lyrics/
├── LyricsPane.swift                   # Overlay in RootView
├── LyricsView.swift                   # The scrollable text itself
├── LyricsEditorSheet.swift
├── LyricsSettingsView.swift
└── ViewModels/LyricsViewModel.swift
```

## Implementation plan

1. **`LRCParser` additions** (if not already complete):
   - Standard timestamps `[mm:ss.xx]` (centiseconds) and `[mm:ss.xxx]` (milliseconds).
   - Multi-timestamp lines: `[00:10.00][00:20.00][00:30.00]Same line sung thrice`.
   - Metadata lines: `[ti:]`, `[ar:]`, `[al:]`, `[by:]`, `[offset:±N]` (apply N ms globally).
   - Enhanced/word-level `<mm:ss.xx>` within a line — parse into an array of `(offset, word)`; v1 UI can ignore the word granularity but store it.
   - Malformed lines preserved as unsynced text mixed into the synced timeline (flag them).
   - Returns a `LyricsDocument` that is either `.unsynced(String)` or `.synced([LyricsLine])` where `LyricsLine = (start: TimeInterval, end: TimeInterval?, text: String, words: [WordTime]?)`. `end` derives from the next line's `start` minus a small gap; last line's end is track duration.

2. **`LyricsService`**:
   ```swift
   public actor LyricsService {
       public init(database: Database, fetcher: LRClibClient?)
       public func lyrics(for trackID: Int64) async throws -> LyricsDocument?
       public func setLyrics(_ doc: LyricsDocument?, for trackID: Int64, persistToFile: Bool) async throws
       public func autoFetchIfMissing(for trackID: Int64) async throws -> LyricsDocument?
       public func observe(_ trackID: Int64) -> AsyncThrowingStream<LyricsDocument?, Error>
   }
   ```

3. **Source priority resolver** — order when reading for display:
   1. User-edited DB row (if flagged `source = 'user'`).
   2. Embedded synced (SYLT / MP4 synced).
   3. Sidecar `.lrc` next to the audio file.
   4. Embedded unsynced (USLT).
   5. Fetched (`source = 'lrclib'`), if present.
   Priority is configurable in Settings: "Prefer embedded" / "Prefer synced" / "Prefer user".

4. **`LyricsView`** — shows either:
   - Unsynced: full text, scrollable, user-selectable.
   - Synced: each line as its own row, current line highlighted with accent colour, neighbours faded with a soft gradient; view scrolls so the current line sits in the vertical centre. Tap a line → `engine.seek(to: line.start)`.
   - Respect `reduceMotion` by disabling smooth scroll (jump to line instead).
   - Large text style by default (readable from arm's length); size toggle in header: S/M/L/XL.

5. **`LyricsPane`** — a right-side overlay in the main window (like Music.app), toggled by `⌘L` and a toolbar button. Remembers width. Also available as a standalone `Window` from the menu.

6. **`LyricsEditorSheet`**:
   - Plain-text editor for the lyrics body.
   - "Insert timestamp at cursor" command (`⌘T`) stamps `[mm:ss.xx]` from current playback position.
   - "Convert to synced" wizard — steps through each line with a spacebar tap at each line; stamps accordingly.
   - Save options: save to DB (always); additionally embed in file (requires Phase 8 write path and settings opt-in).

7. **`LRClibClient`** (opt-in):
   - Base URL: `https://lrclib.net/api/`.
   - Endpoints: `get` (by artist+title+album+duration) and `search`.
   - Set a polite `User-Agent` including app name/version and a contact link.
   - Off by default. When enabled, called automatically when a track with no lyrics starts playing, unless disabled for that specific track (`tracks.lyrics_fetch_disabled` column — add via migration if needed, or use a `lyrics` row with `source = 'user:none'`).

8. **Offset support** — LRC's `[offset:]` tag and a UI slider (−5s to +5s in 50ms steps) for fine-tuning synced lyrics. Offsets saved per track.

9. **Settings (`LyricsSettingsView`)**:
   - Show lyrics pane automatically when a track has lyrics.
   - Font size default.
   - Source priority.
   - Enable LRClib fetch.
   - Allow writing lyrics back into audio files.
   - Ignored tracks list (for auto-fetch).

10. **Keyboard**:
    - `⌘L` toggles pane.
    - `⌘⌥L` opens editor for the current track.
    - In pane, `↑/↓` jump to previous/next line (seeks the engine).
    - `⌘F` focuses a find box in the pane when text is present.

## Definitions & contracts

### `LyricsDocument`

```swift
public enum LyricsDocument: Sendable, Codable, Hashable {
    case unsynced(String)
    case synced(lines: [LyricsLine], offsetMS: Int = 0)

    public struct LyricsLine: Sendable, Codable, Hashable {
        public let start: TimeInterval
        public var end: TimeInterval?
        public let text: String
        public let words: [WordTime]?
    }
    public struct WordTime: Sendable, Codable, Hashable {
        public let start: TimeInterval
        public let word: String
    }
}
```

### `LRClibClient`

```swift
public protocol LRClibClientProtocol: Sendable {
    func get(artist: String, title: String, album: String?, duration: TimeInterval) async throws -> LyricsDocument?
    func search(artist: String?, title: String?, album: String?) async throws -> [LyricsDocument]
}
```

## Context7 lookups

- `use context7 SwiftUI ScrollViewReader scroll animated`
- `use context7 SwiftUI TextEditor formatting macOS`
- `use context7 LRC lyrics format enhanced word timings`
- `use context7 URLSession async retry backoff`

## Dependencies

None new.

## Test plan

- **LRC parser**:
  - Basic `[mm:ss.xx]` text.
  - Multi-timestamp lines.
  - Enhanced word-level within a line.
  - Offset tag applied globally and respected by subsequent seek tests.
  - Malformed line tolerant.
  - Round-trip: serialise a `synced` document to LRC text and re-parse to identical `LyricsDocument`.
- **Sync to playback**:
  - Given a fake engine clock, current line index matches expected line at given times within tolerance (e.g. 50ms).
  - Seek via line-tap dispatches `engine.seek` with the exact `start` timestamp.
- **Source priority**: with embedded + sidecar + user + fetched rows present, the resolver picks according to setting; deleting the current source falls through to the next.
- **Editor**:
  - Pasted plain text saves as `.unsynced`.
  - "Insert timestamp" stamps the correct time at the cursor.
  - Embedded save round-trips through the file (fixture MP3 with USLT, FLAC with `LYRICS` tag).
- **LRClib client**: mock HTTP, happy path + not-found + 429 rate-limit (retries with backoff) + network failure (returns nil, logs a notice).
- **Accessibility**: VoiceOver reads the current line when it changes; respects `reduceMotion`.
- **UI**: snapshot pane open/closed, with synced vs unsynced, with missing lyrics empty state, in both themes.

## Acceptance criteria

- [ ] Embedded synced lyrics show and scroll in time.
- [ ] Unsynced lyrics render cleanly with a readable font.
- [ ] Editor lets me paste, save, and optionally embed into the file.
- [ ] Offset slider fixes slightly-off LRCs.
- [ ] LRClib fetch is opt-in; works when on; never runs without consent.
- [ ] Pane is toggleable by keyboard; state persists.
- [ ] 80%+ coverage on parser and service; snapshots for view.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **SYLT parsing**: ID3v2's SYLT frame has time units (milliseconds or MPEG frames). TagLib exposes milliseconds — verify per file; if frames, convert using the MPEG frame rate.
- **Opus lyrics**: use `LYRICS` Vorbis comment; there's no standard synced Opus tag — write as plain LRC text in that comment.
- **MP4 synced**: AVFoundation/TagLib support varies. If the writer can't round-trip, document and skip writing for MP4 (keep DB-only).
- **Scroll jitter**: calling `ScrollViewReader.scrollTo` on every tick creates jitter. Drive scroll on line-change only and let the animation handle the smoothing.
- **Offset direction**: `[offset:+500]` in LRC typically means lyrics are 500ms behind the audio — adjust by subtracting 500ms from line times. Double-check against multiple tools; it's inconsistent in the wild. Provide the slider in user-facing "seconds ahead/behind" terms.
- **Find box focus**: don't steal focus from `TextEditor` in the editor sheet.
- **Long lyrics**: hundreds of lines — use `LazyVStack`; pin the highlighted line with a frame preference key.
- **User edits vs fetched**: if the user edits, mark `source = 'user'` so future auto-fetches don't overwrite.
- **LRClib abuse prevention**: send `User-Agent` with name + URL + email placeholder; throttle client-side (≤ 1 req/sec per track, cap total fetches per minute).
- **Language & bidi**: some languages are RTL. Don't assume left-aligned; use natural alignment in SwiftUI (`.multilineTextAlignment(.leading)` + RTL-aware containers).
- **Copyright**: note in Settings help text that fetched lyrics may be copyrighted and opt-in use is the user's choice.

## Handoff

Phase 12 (Visualizers) expects:

- The right-side overlay pattern (pane) is reusable; visualizers will optionally share the same surface or replace it in fullscreen mode.
- No lyrics view grabs the audio tap; Phase 12 installs the tap on the engine without contention.
