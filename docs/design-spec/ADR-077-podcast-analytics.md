# ADR-077: Podcast Analytics

> Prerequisites: ADR-001 to ADR-076 complete. The Library Summary window (#373) has
> five live tabs; Podcasts is the last Coming Soon. Everything below works
> against the existing schema (M023 + M027): `podcast_episode_state` carries
> `play_position`, `play_state` (unplayed / inProgress / played),
> `last_played_at`, `completed_at`, `download_state`, `download_path`, and
> `download_bytes`; `podcast_episodes` carries `duration` and `published_at`;
> `podcasts` carries `subscribed` and the per-show `retention_limit`.
> No migration in this ADR.
>
> Read `docs/design-spec/_standards.md` first.

## The brief

The accounting of a subscription habit: what the backlog really costs, which
feeds died, what got downloaded but never heard, and what listening actually
looks like per show. Honest numbers, honest footnotes, and the projection is
allowed to be terrifying.

## Slices

### ADR-077 slice 1: The accounting (Persistence + UI)

`LibraryStatsRepository+Podcasts` with a `LibraryPodcastReport`, plus the
tab's first sections. All figures cover subscribed shows only.

- **Backlog debt**: unplayed episodes at full `duration`, in-progress
  episodes at `duration - play_position`, summed, in hours.
- **Weekly listening rate**: no per-session podcast play log exists, so the
  rate is an estimate: each played / in-progress episode's consumed seconds
  attributed to the week of `COALESCE(completed_at, last_played_at)`, summed
  over the trailing 26 weeks, divided by 26. The UI footnotes the estimate.
- **The projection**: debt divided by rate, rendered as "at your average
  N hrs/week you'll clear this in M months". A zero rate renders "at your
  current rate: never", which is the feature working as intended.
- **Dead feeds**: subscribed shows whose newest `published_at` is older than
  180 days, with the date of the last sign of life.
- **Downloaded, never played**: per show, `download_state = downloaded AND
  play_state = unplayed`: episode count and `SUM(download_bytes)`.
- **Reapable storage**: `play_state = played`, `completed_at` older than 90
  days, `download_path` non-null: count and bytes. Report only in this slice.

### ADR-077 slice 2: The behaviour (Persistence + UI)

- **Completion rate per show**: played over started (played + inProgress),
  with started-episode minimums so a two-episode show cannot top the table.
- **Abandonment point per show**: mean `play_position` (and its share of
  duration) across in-progress episodes with a non-zero position. If the
  average bail is 14 minutes, that is where the ad break is.
- **Episode length creep**: mean duration per calendar year per show,
  rendered as a creep row (first full year's mean, latest year's mean, the
  percent delta), worst first. No thicket of tiny line charts.
- **Time-to-listen**: median gap between `published_at` and first listen,
  where first listen is approximated by `MIN(completed_at, last_played_at)`
  (the schema stores last-played, not first-played; podcasts are
  overwhelmingly listened once, and the UI footnotes the approximation).
  Separates "news, must hear now" from "comfort show, listen whenever".

### ADR-077 slice 3: The actions (UI)

Two reports beg for buttons; both are destructive and sit behind
confirmations, in the pane rather than buried in Settings.

- **Reap Now**: delete the reapable files from disk, reset their
  `download_state` and `download_path`, keep the episode and play state rows
  untouched. Complements the existing per-show `retention_limit`; never
  automatic.
- **Unsubscribe** on dead-feed rows: one click, confirmed, using the
  existing unsubscribe path.

## Non-goals

- No schema changes: `first_played_at` stays unrecorded until an ADR needs
  it exactly (time-to-listen's proxy is footnoted instead).
- No automatic reaping and no background deletion of any kind.
- No per-session podcast play log; the weekly rate stays an estimate.

## Risks

- The rate estimate attributes an episode's whole consumed time to its last
  touch, so a binge week reads spikier than reality. The 26-week window
  smooths this; the footnote owns the rest.
- `download_bytes` is trusted as recorded rather than re-stat'ed from disk;
  if that ever drifts, the hygiene tab's missing-file machinery is the
  precedent for verifying paths at report time.
