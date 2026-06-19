# Phase 21-9: Podcasts UI - Episode list (date, duration, progress indicator), show notes

> Depends on: `phase21-0-overview.md`, `phase21-1-persistence.md`
> (`EpisodeListItem` + observation), `phase21-5-playback.md` (the podcast
> `QueueItem` contract + player), `phase21-7-ui-podcasts-home.md`
> (`PodcastShowView` stub, `PodcastActions`). Touches **UI**.
>
> Provides: the episode list for a subscribed show, with the extra columns the
> brief asks for (date, duration, and a progress indicator: unplayed dot /
> progress bar / played checkmark), live-updating from the state observation, plus
> show notes and an episode context menu.

## Goal

Render a show's episodes like the track list but with podcast columns, taken from
Apple Podcasts because it works well: a leading status indicator (unplayed dot,
in-progress progress, played checkmark), the title, the publish date, and the
duration. Playing an episode resumes from its saved position; the indicator
updates live as the user listens.

## Choice: SwiftUI `Table`, not the AppKit `TrackTable`

The main library track list uses an AppKit `NSTableView` wrapper (`TrackTable`)
because it must scroll 10k rows at 60fps. A podcast show has tens to a few hundred
episodes, so that machinery is unnecessary here. Use SwiftUI's macOS `Table`
(or a `List` if `Table` proves awkward with the custom status column). This keeps
the slice native, much simpler for the implementer, and consistent with SwiftUI
elsewhere. Document this choice in a comment; if a future show with thousands of
episodes ever stutters, revisiting with an `EpisodeTable` AppKit wrapper modelled
on `TrackTable` is the escape hatch.

## `PodcastShowView`

Fills the stub from phase 21-7. Routed from `ContentPane` for
`.podcastShow(id)`.

```swift
public struct PodcastShowView: View {
    @ObservedObject var vm: PodcastsViewModel
    var library: LibraryViewModel
    let podcastID: Int64

    public var body: some View {
        VStack(spacing: 0) {
            PodcastShowHeader(podcast: vm.currentShow)      // artwork, title, author, refresh, settings
            Divider()
            EpisodeList(vm: vm, library: library)
        }
        .task(id: podcastID) { await vm.loadShow(podcastID) }
        .navigationTitle(vm.currentShow?.title ?? L10n.string("Podcast"))
    }
}
```

`vm.loadShow(id)` (phase 21-7) fetches the show and starts
`observeEpisodes(podcastID:)`, so `vm.episodes: [EpisodeListItem]` updates live as
positions are written during playback (the player writes state every ~5 s; the
join observation re-fires; the indicator moves).

### Header

`PodcastShowHeader`: large artwork (`Artwork(artPath:)` from
`podcast.artworkPath`), title + author (feed content), a one-line truncated
description with a "more" disclosure, and actions: **Refresh** (->
`actions.refresh`), **Mark all as played**, **Settings** (auto-download toggle
-> `actions.setAutoDownload`), **Unsubscribe…**. A back affordance returns to the
grid (`library.selectDestination(.podcasts)`), matching how album detail returns.

## The episode table

Columns (the brief's list, plus the title):

| Column | Content | Notes |
|--------|---------|-------|
| Status | unplayed dot / progress / played check | leading, fixed narrow width, custom cell |
| Title | `episode.title` (feed content) | primary, truncates; subtitle line optional |
| Date | `episode.publishedAt` | `RelativeDateTimeFormatter` or short date; right-size |
| Duration | `episode.duration` (or remaining) | `Duration`/formatter, monospaced digits |
| (Download) | download badge / button | only meaningful with phase 21-6; show always-empty otherwise |

`Table` sketch:

```swift
Table(vm.episodes) {
    TableColumn("") { item in EpisodeStatusIndicator(item: item) }
        .width(28)
    TableColumn(L10n.string("Episode")) { item in
        EpisodeTitleCell(item: item)        // title + optional 2nd line (subtitle/date on compact)
    }
    TableColumn(L10n.string("Published")) { item in
        Text(Self.relativeDate(item.episode.publishedAt))   // chrome formatter; date value is content
    }.width(min: 80, ideal: 110, max: 160)
    TableColumn(L10n.string("Length")) { item in
        Text(Self.durationLabel(item))
    }.width(min: 60, ideal: 72, max: 96)
}
.contextMenu(forSelectionType: EpisodeListItem.ID.self) { ids in episodeContextMenu(ids) }
```

(SwiftUI `Table` column headers take `LocalizedStringKey`; pass `Text(localized:)`
or `L10n.string`. Confirm header localization resolves against the module catalog,
the same care as everywhere else.)

Double-click / Return on a row plays the episode (resumes). Single selection
drives the show-notes inspector (below). Provide keyboard navigation (arrow keys
+ Return) and `accessibilityLabel`s that encode status ("Episode title, 12
minutes left, in progress").

### `EpisodeStatusIndicator` (the heart of the brief)

Derive purely from `item.state` + `item.episode.duration`. Use the shared
`PodcastPlayback.completionTailSeconds` constant (phase 21-4) so "played" agrees
across player, service, and UI.

```swift
struct EpisodeStatusIndicator: View {
    let item: EpisodeListItem
    var body: some View {
        switch status(item) {
        case .unplayed:
            Circle().fill(Color.accentColor).frame(width: 8, height: 8)          // filled dot
                .accessibilityLabel(L10n.string("Unplayed"))
        case let .inProgress(fraction):
            // a small determinate ring or a thin bar showing `fraction`
            ProgressRing(fraction: fraction).frame(width: 16, height: 16)
                .accessibilityLabel(L10n.string("In progress"))
        case .played:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.textSecondary)
                .accessibilityLabel(L10n.string("Played"))
        }
    }
}

enum EpisodeStatus { case unplayed; case inProgress(Double); case played }

func status(_ item: EpisodeListItem) -> EpisodeStatus {
    guard let s = item.state else { return .unplayed }
    switch s.playState {
    case .played: return .played
    case .unplayed: return .unplayed
    case .inProgress:
        let dur = item.episode.duration ?? 0
        let frac = dur > 0 ? min(max(s.playPosition / dur, 0.02), 0.99) : 0.5
        return .inProgress(frac)
    }
}
```

- **Unplayed**: a filled accent dot (Apple's affordance).
- **In progress**: a small determinate ring (or thin bar) reflecting
  `position / duration`. Clamp so it is visibly non-empty/non-full.
- **Played**: a checkmark, quiet (secondary colour).
- Respect `differentiateWithoutColor`: the three states differ by **shape**
  (dot / ring / check), not only colour, so this already passes; keep it that
  way.

### Duration label

Show the full duration for unplayed/played, and **time remaining** for
in-progress ("12 min left"), which is the genuinely useful number while
listening. Use a `Duration`/`DateComponentsFormatter`-based helper; monospaced
digits so the column does not jitter.

## Show notes

When a row is selected, show its notes. Episode descriptions are **HTML** from
the feed. Two acceptable renderings, pick one:

1. Convert to `AttributedString` via `NSAttributedString(html:)` on a background
   actor (it is main-thread-hostile and slow; do it once per selection, cache by
   guid), strip scripts, render in a scrollable panel. Links open in the default
   browser (respect the link-safety norms; open via the system, do not auto-load).
2. A minimal HTML-to-text+links pass if the full `AttributedString(html:)` proves
   too heavy.

Present notes as an inspector/sidebar panel or an expandable section under the
selected row. Keep the table the focus; notes are secondary.

## Playing an episode

Row play action -> `actions.play(episode:podcast:)` (the App implementation,
phase 21-7/21-5). The App builds the podcast `QueueItem` per the field contract
in phase 21-5 (`title` = episode, `artistName` = show, source
`.podcast(feedURL, guid)`), enqueues, and the player resumes from the saved
position. The UI just fires the action and lets the state observation update the
indicator.

"Play" semantics: play this episode now. Optionally a "Play Next" / "Add to Up
Next" in the context menu queues it. A "Play all from here (newest->oldest or
oldest->newest)" is a nice-to-have; episodes are usually consumed newest-first or
in publication order, so offer an oldest-first "Play from oldest" too.

## Episode context menu

`actions` from phase 21-7 cover these:

- **Play** / **Play Next**.
- **Mark as Played** / **Mark as Unplayed** (-> `actions.markPlayed` /
  `markUnplayed`; the indicator flips live).
- **Download** / **Remove Download** (phase 21-6; show but disable/hide cleanly
  when downloads are not built).
- **Copy Episode Link** (`episode.link`), **Copy Audio URL**.
- **Go to Website** (`episode.link` via the system browser).
- **Show Notes** (focuses/opens the notes panel).

## Filtering / search within a show

A small filter field in the header that filters `vm.episodes` by title via a
simple case-insensitive `contains` (the list is small; no FTS). Optional:
segmented "All / Unplayed / Downloaded" filter, which is genuinely useful for
long-running shows. Keep filtering client-side over the observed array.

## Context7 lookups

- SwiftUI `Table` on macOS: custom column cells, selection, `contextMenu(
  forSelectionType:)`, column width control, and localizing column headers.
- `NSAttributedString(html:)` / `AttributedString` for show-notes rendering and
  its main-thread constraints.

## Test plan

- **Status derivation** (pure function `status(_:)`): unplayed (no state row),
  in-progress fraction from position/duration with clamping, played; the
  completion-tail constant is respected.
- **Duration label**: remaining-time for in-progress, full for others; formats
  H:MM:SS and MM:SS inputs.
- **PodcastShowView / EpisodeList** snapshot (`make test-ui`): a show with a mix
  of unplayed/in-progress/played episodes renders the three indicators; light +
  dark; `differentiateWithoutColor` variant shows distinct shapes.
- **Live update** (view-model test): a state observation update moves an episode
  from unplayed to in-progress in `vm.episodes`.
- **Context menu actions** call the right `PodcastActions` methods.
- **Show notes**: HTML converts without crashing; a script tag is stripped.
- **L10n**: column headers, status labels, menu items, filter copy localized with
  `en-XA`; `make pseudolocale` run.

## Acceptance criteria

- [ ] A subscribed show opens to an episode list with Status, Title, Published,
      Length columns.
- [ ] The status indicator shows a dot (unplayed), a progress ring/bar
      (in-progress, reflecting saved position), or a checkmark (played), and
      updates live during playback via the state observation.
- [ ] In-progress rows show time remaining; played/unplayed show full duration.
- [ ] Double-click / Return plays and **resumes** the episode from its saved
      position (the resume itself is phase 21-5; verify end-to-end).
- [ ] Show notes render the episode's HTML safely; selection drives the panel.
- [ ] The context menu covers play, mark played/unplayed, download (when built),
      copy link, go to website.
- [ ] State differs by shape, not colour alone (`differentiateWithoutColor`
      passes); all chrome localized; `make pseudolocale` run.
- [ ] `make test-ui` green; no lint (incl. `file_length`) or format warnings.

## Gotchas

- **Live indicators come for free from the join observation** (phase 21-1's
  `observeEpisodes` tracks both `podcast_episodes` and `podcast_episode_state`).
  Do not poll; subscribe to the stream in `loadShow` and let SwiftUI diff.
- **`HTML -> AttributedString` is slow and main-thread-touchy.** Convert off the
  main actor, cache per guid, never on every redraw. A long show-notes blob can
  jank the list if converted inline.
- **Column header localization.** SwiftUI `Table` headers are
  `LocalizedStringKey`; in this SPM module that resolves against `Bundle.main`
  unless routed through the module catalog. Use `Text(localized:)` / `L10n` and
  verify the keys exist (the `no_bare_user_facing_literal` rule + `L10nTests`
  guard this).
- **Completion threshold must match the player.** Use the shared
  `PodcastPlayback.completionTailSeconds`; if the UI calls "played" at a different
  boundary than the player marks played, the checkmark and the engine disagree.
- **Episode titles / notes are feed content**, rendered verbatim; only chrome is
  localized.
- **Date formatting is chrome** (`RelativeDateTimeFormatter` etc.), the date
  value is content; use a `Formatter`, never hand-built strings (a
  standards requirement).
- **`Table` selection type** must be `EpisodeListItem.ID` (the episode rowid);
  keep ids stable across observation updates so selection survives a refresh.

## Handoff

Phase 21-10 renders the playing episode in Now Playing's podcast mode (show art,
episode title, show name) and adds skip/speed transport, plus the Podcasts
settings pane (auto-download, refresh interval, storage). The episode list here
is the primary play surface that feeds it.
