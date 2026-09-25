# ADR-095: Crossfade That Overlaps

> Depends on: ADR-002 (the engine graph and the insertion point), ADR-006
> (gapless prefetch, `GaplessScheduler`), ADR-013 (the crossfade setting and
> its acceptance criterion), ADR-091 (the canonical stereo output format and
> the pump's `FormatConverter`).
> Binding docs: `_standards.md`; the concurrency, logging and testing
> sections of the root `CLAUDE.md`; the audio entries in `docs/GOTCHAS.md`.
> Reported in #567, 2026-09-24. Design chosen by the maintainer, 2026-09-25:
> mix the two tracks inside the buffer pump, on the one player node.

Everything under "Facts the plan rests on" was read from the code on
`main` at `0bb9d939` (2.18.0) and from the log attached to #567.

## Goal

Make crossfade do what the word means in every other player: during the
last seconds of a track, the next track fades in **while** the current one
fades out, and both are audible at the same time.

Today Bòcan fades the current track to silence, lets it end, then fades the
next one in from silence. That is a dip through silence, not a crossfade.
ADR-013's own acceptance criterion ("audio from two consecutive tracks
overlaps") was never met, and no test checked it.

The overlap is built inside `BufferPump`: during the overlap window one pump
reads from both decoders, applies an equal-power gain curve to each, adds
the samples, and schedules the mixed buffer on the single
`AVAudioPlayerNode`. The node, the transport gate, pause, the tap and the
DSP chain see one continuous stream, exactly as they do today.

Two defects found while reading the code are fixed here because the
crossfade cannot work without them:

- With the default settings, crossfade never runs at all (see Facts, item 6).
- The arming window is the gapless preroll (default 5 s), which is shorter
  than a long crossfade (up to 10 s).

## Non-goals

- **ReplayGain at playback.** `GainApplication` and
  `AudioEngine.applyReplayGain(db:)` have no production callers, so no
  ReplayGain value is applied to playback today in any mode. That is a
  separate defect with its own issue. This ADR does not wire it, but the
  mix design keeps a per-source gain point for it (see Gotchas).
- **Crossfade for Subsonic, podcast and internet-radio items.** Gapless
  prefetch only works for local files (`performGaplessPrefetch` requires a
  file on disk), so crossfade inherits that scope. Streams keep today's hard
  transition. A later ADR can extend it.
- **Smart transitions.** No silence trimming at track edges, no beat
  matching, no loudness-matched curves, no per-genre rules (ADR-013 already
  puts DJ-style crossfade out of scope).
- **Crossfade on manual skips.** Next, Previous, double-click and queue jumps
  stay instant, as in Apple Music and Spotify. Only natural track ends
  crossfade.
- **A choice between "dip" and "overlap" modes.** The dip goes away. It is
  not a mode any comparable player ships for natural track changes, and the
  maintainer has never used it.
- **Fixing the ~0.8 s early transition of the plain gapless path.** The
  gapless handoff fires when the outgoing decoder reaches EOF, about four
  buffers before the audio stops. The crossfade path in this ADR gets an
  exact transition moment; moving plain gapless to the same mechanism is a
  follow-up, not part of this change.
- **New settings or schema.** The existing `crossfadeSeconds` (0 to 10 s)
  and `crossfadeAlbumGapless` keep their keys and defaults. No migration.

## Outcome shape

```
Modules/AudioEngine/Sources/AudioEngine/
├── Graph/
│   ├── BufferPump.swift              # refactored around PumpSource; overlap mode
│   ├── PumpSource.swift              # NEW: decoder + converter + frame accounting
│   └── CrossfadeMix.swift            # NEW: pure equal-power mixing of two buffers
├── AudioEngine+GaplessAPI.swift      # + enableCrossfadeNext(url:overlap:onTransition:)
├── AudioEngine+Gapless.swift         # overlap transition handling
├── AudioEngine+Crossfade.swift       # DELETED (node-volume ramps)
└── AudioEngine.swift                 # crossfadeTask and cancelCrossfade() removed

Modules/AudioEngine/Tests/AudioEngineTests/
├── Support/ScriptedDecoder.swift     # NEW: one shared fake decoder (tone, length, EOF)
├── CrossfadeMixTests.swift           # NEW: pure curve and mix tests
├── BufferPumpOverlapTests.swift      # NEW: pump overlap, early/late EOF, seek, stop
└── CrossfadeRenderTests.swift        # NEW: offline manual-rendering proof of overlap

Modules/Playback/Sources/Playback/
├── Gapless/CrossfadeScheduler.swift  # shrinks to config + decisions (ramps deleted)
├── Gapless/GaplessScheduler.swift    # arming window grows with the overlap
└── QueuePlayer.swift                 # crossfade path via enableCrossfadeNext; ramp code deleted

Modules/Playback/Tests/PlaybackTests/
├── CrossfadeDecisionTests.swift      # NEW: boundary and arming-window tables
├── CrossfadeSchedulerTests.swift     # ramp tests removed, overlapSeconds
└── CrossfadeDelayClampTests.swift    # DELETED with the function it tests

Modules/UI/Sources/UI/DSP/DSPView.swift      # copy: says the tracks overlap
Modules/UI/Sources/UI/Resources/Localizable.xcstrings
CHANGELOG.md, README.md, website pages       # fix note and feature text
docs/GOTCHAS.md                              # new entry (see Handoff)
```

## What carries over from previous specs

- **ADR-006:** the prefetch contract. The next track is opened ahead of
  time by `GaplessScheduler` through `QueuePlayer.performGaplessPrefetch`,
  which does the security-scope work. The crossfade path reuses that exact
  entry point; only the engine call at its end changes.
- **ADR-013:** the settings (`crossfadeSeconds`, `crossfadeAlbumGapless`),
  the UI section, and the acceptance criteria: overlap without a click at the
  ramp start or end; at 0 s, output identical to the gapless path; with
  "keep gapless within albums", same-album boundaries stay gapless.
- **ADR-091:** every pump converts its source to the canonical stereo output
  format with its own `FormatConverter`. That is what makes mixing possible:
  both sources are in the same format after conversion, whatever their file
  rate or channel count.
- **The transport gate** (`docs/GOTCHAS.md`, "Transport operations stay
  behind the async-mutex gate"): play, pause, seek, stop and the device
  change handler stay serialized. Nothing in this ADR adds a transport entry
  point outside the gate.

## Implementation plan

### Facts the plan rests on (read 2026-09-25)

1. **One player node.** `EngineGraph` owns one `AVAudioPlayerNode`
   (`Graph/EngineGraph.swift:24`). The chain is PlayerNode, TimePitch,
   GainStage, EQ, BassBoost, Crossfeed, StereoExpander, Limiter, Mixer.
2. **Today's "crossfade" is a dip.** `QueuePlayer.performGaplessPrefetch`
   schedules `engine.beginCrossfadeOut` at `remaining - halfDuration`
   (`QueuePlayer.swift:1325-1346`); it ramps the node volume to 0.
   `handleGaplessTransition` then calls `engine.beginCrossfadeIn`
   (`QueuePlayer.swift:1399-1406`), which sets the node volume to 0 and ramps
   it up. Both ramp the same node, so the tracks never overlap. The #567 log
   shows `crossfade.out.start`, `pump.eof`, `engine.gapless.transition`,
   `crossfade.in.start` in that order.
3. **Dead two-node code.** `CrossfadeScheduler.scheduleOutgoingFade` and
   `scheduledIncomingFade` describe two nodes and are never called.
4. **The gapless handoff fires early.** The outgoing pump reports EOF when
   its decoder returns 0 frames, while four 200 ms buffers are still queued
   on the node (`BufferPump.windowSize = 4`, `bufferDuration = 0.2`).
   `performGaplessTransition` then rebaselines the position and emits the
   transition at once, about 0.8 s before the new track is heard.
5. **Arming window.** `GaplessScheduler.checkAndArm` arms only when
   `remaining <= preroll` (default 5 s, user range 1 to 15 s, key
   `playback.gaplessPrerollSeconds`) and polls every 500 ms.
6. **Crossfade is never armed with default settings.**
   `QueuePlayer.resolveNextGaplessItem` returns `nil` at an album boundary
   unless `playback.crossAlbumGapless` is on (default off). With the default
   `crossfadeAlbumGapless = true`, crossfade applies only at album
   boundaries. So a user who only moves the crossfade slider gets no
   crossfade anywhere. The #567 reporter had turned both toggles on.
7. **The format gate does not apply to a mix.** `GaplessScheduler` refuses to
   arm when the sample rate or channel count differ (`FormatBridge`),
   because plain gapless appends raw buffers to one FIFO. A mixed buffer is
   built after each source's own conversion, so the gate is not needed for
   the crossfade path.
8. **Transport and teardown paths that touch the pump:** `load`,
   `performStop`, `performSeek` (in-place `reschedule`, or a rebuild for a
   CUE segment), `performPause` / `resumePausedNode`,
   `handleDefaultDeviceChange` (stops the pump and builds a new one from
   `decoder`), and the stream reconnect path (streams only, so not reachable
   in an overlap).
9. **The limiter is always in the chain** (`LimiterUnit`: "never bypassed").
   A sum of two loud tracks that exceeds full scale in Float32 is caught
   there.
10. **Test fakes are duplicated.** `BufferPumpEndedTests`,
    `BufferPumpFormatTests`, `BufferPumpSegmentTests` and
    `BufferPumpWindowTests` each declare their own private fake decoder. No
    test in the repo renders audio offline (`enableManualRenderingMode` has
    no uses).
11. **Decoder facts are read at `.ready`** (`docs/GOTCHAS.md`, "The
    current-track change arrives before the decoder is open"). The gapless
    item stream carries the codec facts across a gapless handoff; the
    crossfade handoff must do the same.

### Slice 1: the mixing core and the shared test decoder

Pure code, no graph, no actors. Nothing calls it yet.

1. `Graph/CrossfadeMix.swift`: an `enum CrossfadeMix` (a namespace, like
   `AudioTime`) with:
   - `static func gains(atFrame frame: Int, of length: Int) -> (out: Float, in: Float)`,
     the equal-power pair defined under Behavioural definitions.
   - `static func mix(outgoing: AVAudioPCMBuffer?, incoming: AVAudioPCMBuffer, into output: AVAudioPCMBuffer, startFrame: Int, length: Int)`,
     which writes `out[i] = a[i] * gOut(startFrame + i) + b[i] * gIn(startFrame + i)`
     per channel. A `nil` or short `outgoing` contributes silence for the
     missing frames. Use Accelerate (`vDSP`) for the multiply-add; build the
     gain ramps once per buffer, not per sample call.
   - Precondition-free: mismatched formats or capacities throw a new
     `AudioEngineError.crossfadeFormatMismatch(expected:actual:)` case (add it
     to the module's one public error enum; do not add a new error type).
2. `Tests/AudioEngineTests/Support/ScriptedDecoder.swift`: one shared
   `ScriptedDecoder: Decoder` that produces a constant or sine tone at a
   given amplitude for an exact frame count, reports a configurable
   `duration` (which may be deliberately wrong, for the early and late EOF
   tests), supports `seek`, and counts `read` calls. Migrate the four
   private fakes to it where the migration is mechanical; keep a private
   fake only where a test needs behaviour the shared one does not have, and
   say why in a comment.
3. `CrossfadeMixTests`: see Test plan.

Commit: `feat(audio): equal-power crossfade mix core`. No user-visible change,
so no CHANGELOG entry yet (label the PR `skip-changelog` if it lands alone).

### Slice 2a: `PumpSource`, a refactor with no behaviour change

1. Extract from `BufferPump` a `PumpSource` (internal final class, owned by
   exactly one pump at a time): the decoder, its `FormatConverter?`, the
   `pumpFormat`, `maxFrames`, and running counters `framesRead` (decoder
   frames) and `outputFramesProduced` (output-rate frames after conversion).
   It exposes `readConverted(maxOutputFrames:) async throws -> AVAudioPCMBuffer?`
   (nil at EOF).
2. `BufferPump` keeps its public surface and log lines exactly; its feed
   loop reads through `current: PumpSource`.
3. Every existing BufferPump, EngineTransport, GapFreeSeek, FoldParity and
   RetainCycle test passes unchanged. That is the acceptance test for this
   slice.

Commit: `refactor(audio): read the buffer pump through a PumpSource`.

### Slice 2b: overlap mode in the pump and the engine

1. **Arming.** `BufferPump.armOverlap(next: PumpSource, lengthFrames: Int, onTransition: @Sendable () -> Void)`.
   Stores the incoming source and the overlap length in output frames. Can be
   called while the feed loop runs; takes effect at the next loop iteration.
   `disarmOverlap()` drops and closes an incoming source that has not started
   mixing.
2. **When the mix starts.** Each iteration, before reading, the pump computes
   `remainingOutgoing = estimatedTotalOutputFrames - current.outputFramesProduced`,
   where `estimatedTotalOutputFrames = round(decoder.duration * outputRate)`
   (minus `segmentStart` handling if a CUE segment is ever armed; today none
   is). When `remainingOutgoing <= lengthFrames`, the overlap starts.
3. **Exact boundary.** The buffer read just before the boundary is shortened
   so it ends exactly at `estimatedTotal - lengthFrames`; the first mixed
   buffer starts on that frame. No mixed buffer ever contains unmixed frames.
4. **Mixing.** During the overlap each iteration reads up to one buffer from
   each source (both already converted), calls `CrossfadeMix.mix` with the
   running overlap frame, and schedules the result. Slot accounting is
   unchanged: one scheduled buffer is one slot.
5. **The exact transition moment.** The completion handler of the last
   unmixed buffer (`.dataPlayedBack`) is the moment the mixed audio starts to
   be heard. The pump fires `onTransition` from that handler (hopping to the
   engine the same way `onEnded` does today). This is the crossfade
   counterpart of the gapless handoff, without the ~0.8 s early fire.
6. **Promotion.** When the overlap frame reaches `lengthFrames`, the
   outgoing source is closed and the incoming source becomes `current`. The
   pump continues as a normal single-source pump. Its id does not change.
7. **Early EOF** (the outgoing decoder ends before the overlap ends, because
   `duration` overestimated the length): the outgoing contributes silence for
   the rest of the window; the incoming keeps its curve. Log
   `crossfade.mix.early_eof` with the frames missing.
8. **Late EOF** (the outgoing still has frames when the overlap ends): drop
   them; their gain is 0. Log `crossfade.mix.truncated_tail` with the frames
   dropped. Neither case fires `onEnded`.
9. **Engine API.** `AudioEngine.enableCrossfadeNext(url:overlapSeconds:onTransition:)`
   in `AudioEngine+GaplessAPI.swift`: opens the decoder with
   `DecoderFactory.make(for:)`, builds a `PumpSource` with its own converter
   to the current output format, clamps the overlap (see Behavioural
   definitions), and arms the live pump. `cancelGaplessNext()` also disarms a
   pending overlap.
10. **Engine transition.** On `onTransition` the engine does what
    `performGaplessTransition` does for a track change, minus the pump swap:
    the pending decoder becomes `decoder`, `_duration` becomes the incoming
    duration, `_currentTime = 0`, `_playerTimeOffset` is rebaselined to the
    node's sample time at that callback, `lastState = nil; emit(.playing)`,
    `lastGaplessTransitionAt = Date()`, and the stored transition closure
    runs. The codec facts follow the same path as a gapless handoff (Facts,
    item 11).
11. **Transport during an overlap** (all inside the existing gate):
    - pause and resume: unchanged. One node, so both sources pause and
      resume together, mid-curve.
    - seek before the overlap has started: the armed source stays armed;
      `reschedule` resets `current.outputFramesProduced` from the seek
      target, so the start is recomputed. If the target lands inside the
      window, the overlap starts at once with its length shortened to the
      remaining frames.
    - seek after the transition: the seek is for the incoming (now current)
      track. The outgoing source is closed at once; the node is flushed and
      muted by the existing seek path, so no outgoing audio is heard.
    - stop, load (Next, Previous, a queue jump): tear down both sources.
      `load` already stops the pump and cancels the pending next.
    - output device change: before the transition, disarm and close the
      incoming source (the scheduler will not re-arm the same item, so the
      boundary becomes a normal load); after the transition, the outgoing
      source is dropped and playback resumes from the incoming decoder,
      which is already `decoder`.
12. **Deletions.** `AudioEngine+Crossfade.swift` (both ramps and
    `cancelCrossfade()`), the `crossfadeTask` property, and the two
    `cancelCrossfade()` calls in `load` and `performStop`.

Commit: `fix(audio): mix the next track into the current one during a crossfade`.

### Slice 3: the playback wiring

1. **Decision.** `CrossfadeScheduler` keeps `Config`, `setConfig`,
   `crossfadeAllowed(currentAlbumID:nextAlbumID:)`, `isEnabled`, and gains
   `overlapSeconds` (the full setting value). Delete `halfDurationSeconds`,
   both node ramps, `cancelFades`, and the task handles.
2. **Arming window.** A pure static function
   `GaplessScheduler.armingWindow(preroll:crossfadeSeconds:) -> TimeInterval`
   returning `max(preroll, crossfadeSeconds + 2.0)` when crossfade is enabled
   for this boundary, else `preroll`. The 2 s margin covers the 500 ms poll,
   the decoder open, and the prefetch hop. `checkAndArm` uses it.
3. **The crossfade path bypasses two gates** that exist only for raw
   gapless: the `FormatBridge` compatibility check (Facts, item 7) and the
   `playback.crossAlbumGapless` requirement in `resolveNextGaplessItem`
   (Facts, item 6). The decision order at a boundary is:
   1. No next item, or stop-after-current: no arming (as today).
   2. The next item is not a local file: today's behaviour, unchanged.
   3. `crossfadeAllowed(...)` is true: arm a crossfade, whatever the formats
      and the cross-album toggle.
   4. Otherwise: today's gapless rules, unchanged.
4. **QueuePlayer.** `performGaplessPrefetch` calls
   `engine.enableCrossfadeNext` instead of `enableGaplessNext` when the
   boundary crossfades, with the same `onTransition` callback. Delete
   `crossfadeOutTask`, `crossfadePendingForNextTransition`, the fade-out
   scheduling block, the fade-in block in `handleGaplessTransition`, and
   `crossfadeOutDelaySeconds` with `maxCrossfadeOutDelaySeconds`. Delete
   `CrossfadeDelayClampTests.swift` (#271), which tests only that function;
   the non-finite-duration concern moves to `armingWindow`, which must return
   a finite value for any input and gets the same NaN and infinity cases.
   In `CrossfadeSchedulerTests.swift`, drop the ramp and `cancelFades` tests
   and move the `halfDurationSeconds` assertions to `overlapSeconds`.
5. **History.** `handleGaplessTransition` already credits the outgoing play
   as a natural end. Keep that: a crossfaded track counts as played in full.

Commit: `fix(playback): arm a real crossfade at the boundaries the setting names`.

### Slice 4: copy, docs and the release note

1. `DSPView`: the slider help says the next track fades in while the current
   one fades out. Replace the `"0 s = sample-accurate gapless (Phase 5
   path)."` caption, which leaks a phase name to users, with plain copy.
   Keep every key localized; run `make pseudolocale`.
2. `CHANGELOG.md` under Unreleased (fix): one or two plain sentences, for
   example "Crossfade now overlaps songs: the next song fades in while the
   current one fades out, instead of both fading through silence. It also
   works with the default settings now." Follow the release-note style
   rules (no code names, no issue numbers).
3. README and the website: describe crossfade as an overlap, where the
   feature list mentions it.
4. Close #567 from the PR body (`Closes #567.`).

Commit: `docs(ui): say what crossfade does, and note the fix`.

## Behavioural definitions and contracts

**Overlap length.** With setting `D` seconds (`crossfadeSeconds`, 0.5 s
steps, 0 to 10), outgoing duration `A` and incoming duration `B`:

```
L = min(D, A / 2, B / 2)
```

If `L < 1.0` s, the boundary does not crossfade: it follows the plain
gapless rules instead. `L` is converted to output frames as
`round(L * outputSampleRate)`.

**Gain curves (equal power).** For overlap frame `n` in `0 ..< N`, with
`t = n / N`:

```
gOut(n) = cos(t * π / 2)
gIn(n)  = sin(t * π / 2)
```

So `gOut(0) = 1`, `gIn(0) = 0`, `gOut² + gIn² = 1` for every frame, and the
curves meet at `t = 0.5` with both at `√½ ≈ 0.7071` (-3 dB each). For two
uncorrelated signals of equal loudness, the summed power stays constant
through the overlap. After the overlap the incoming gain is exactly 1.0 and
the samples pass through unchanged (bit-identical to a pump with no overlap).

**Where the new track starts.** The first mixed frame is frame 0 of the
incoming track. `currentTime` for the incoming track is 0 at the moment that
frame is heard (the `.dataPlayedBack` of the last unmixed buffer), and counts
up from there. The outgoing track's last `L` seconds are never shown as its
own position.

**When "now playing" changes.** At the same moment: the `onTransition`
callback, the Now Playing centre, the history start of the incoming track,
and the codec badges all move to the incoming track when the overlap starts
to be heard. Not when it is scheduled, and not at its midpoint.

**Which boundaries crossfade.** A boundary crossfades if and only if all of
these hold:

| Condition | Source |
|---|---|
| `crossfadeSeconds > 0` | DSP settings |
| the transition is a natural end (no skip, no queue jump) | QueuePlayer |
| there is a next item and stop-after-current is off | `resolveNextGaplessItem` |
| both items are local files | prefetch scope |
| not (`crossfadeAlbumGapless` and both items share an album ID) | `crossfadeAllowed` |
| `L >= 1.0` s | overlap length rule |

`playback.crossAlbumGapless` and format differences have no effect on this
decision.

**At 0 s.** With `crossfadeSeconds == 0` no code in this ADR runs. The
output is bit-identical to the plain gapless path, and the plain gapless
path is unchanged.

**Log events** (category `audio` for the engine and pump, `playback` for the
decision): `crossfade.armed [lengthMs next]`, `crossfade.mix.start`,
`crossfade.transition [trackID]`, `crossfade.mix.end`,
`crossfade.mix.early_eof [missingFrames]`,
`crossfade.mix.truncated_tail [droppedFrames]`,
`crossfade.disarmed [reason]`, and in `playback`,
`crossfade.decision [crossfade|gapless|none reason]`. No file paths beyond
`lastPathComponent`, as elsewhere in the engine.

## Context7 lookups

Per the root `CLAUDE.md`: choose the latest SDK documentation and avoid
deprecated APIs. If a lookup contradicts this spec, stop and ask.

- `AVAudioEngine enableManualRenderingMode offline renderOffline` (the
  render test in slice 2b).
- `AVAudioPlayerNode scheduleBuffer completionCallbackType dataPlayedBack`
  (the transition moment; confirm the callback fires once per buffer and
  after the buffer is heard, on the current macOS SDK).
- `AVAudioPlayerNode playerTime sampleTime lastRenderTime` (the position
  rebaseline at the callback).
- `Accelerate vDSP multiply add ramp` (the mix loop; prefer the Swift
  `vDSP` overlay over the C functions).

## Dependencies

None new. AVFoundation and Accelerate are system frameworks already linked
by `AudioEngine`.

## Test plan

**Unit, `CrossfadeMixTests` (slice 1):**
- `gains(atFrame: 0, of: N)` is `(1, 0)`; at `N` it is `(0, 1)`; at `N / 2`
  both are `0.7071 ± 1e-4`.
- `gOut² + gIn² == 1 ± 1e-6` for every frame of `N = 44100`.
- Mixing a constant `1.0` outgoing with a constant `0.0` incoming reproduces
  `gOut` exactly; the reverse reproduces `gIn`.
- A mix that starts at `startFrame = 1000` of `N` uses the gains of frames
  1000 onward (the curve continues across buffer boundaries).
- A `nil` or short outgoing buffer yields `incoming * gIn` for the missing
  frames.
- Mismatched formats throw `crossfadeFormatMismatch`.

**Unit, `CrossfadeDecisionTests` (slice 3):** a table over the six
conditions in "Which boundaries crossfade", including the default settings
case (crossfade on, keep-gapless on, cross-album gapless off, different
albums: must crossfade), and `armingWindow` for `D` in {0, 3, 10} with
preroll in {1, 5, 15}.

**Integration, `BufferPumpOverlapTests` (slice 2b, `ScriptedDecoder`):**
- The mix starts on exactly frame `estimatedTotal - N` of the outgoing
  source (count frames through the scheduled buffers).
- `onTransition` fires once, after the last unmixed buffer's completion, and
  `onEnded` does not fire for the outgoing source.
- Early EOF (duration reports 10 s, source has 9 s) and late EOF (reports
  9 s, source has 10 s) both complete the overlap, log their event, and
  leave the incoming source current.
- `disarmOverlap()` before the mix closes the incoming decoder
  (`ScriptedDecoder` records `close`).
- stop during the overlap closes both decoders.

**Integration, `CrossfadeRenderTests` (slice 2b, the proof for #567):**
put the engine graph in offline manual rendering mode, play a 3 s constant
tone `A = 0.5` into a 3 s constant tone `B = 0.25` with a 1 s overlap, and
render the whole output:
- Before the overlap, output is `0.5` (within DSP flat-chain tolerance).
- At the overlap midpoint, output is `0.5 * 0.7071 + 0.25 * 0.7071 ≈ 0.530`,
  so both are present at once. This is the assertion the old code fails.
- After the overlap, output is `0.25`.
- No sample-to-sample step larger than the curve slope plus `1e-3` at the
  overlap start and end (no click).
- With `crossfadeSeconds = 0`, the rendered output equals the plain gapless
  render bit for bit.

If manual rendering cannot drive `AVAudioPlayerNode` with the DSP chain
attached on the CI runner, render the node alone into the mixer (the chain
is not what is under test), and record that in the test's doc comment.

**Existing suites:** `make test-audio-engine` and `make test-playback` in
full after each slice (these modules own the change), `make test-coverage`
before the PR. Per the cost rule, targeted `--filter` runs while iterating,
not loops.

**Manual check for the maintainer (slice 4, before merge):** two songs from
different albums, crossfade 6 s, default toggles. Expected: the second song
is audible under the end of the first for about 6 s; the play bar switches
to the second song when it becomes audible; pausing mid-overlap and resuming
continues the overlap.

## Acceptance criteria

1. With crossfade at `D` seconds, at a crossfading boundary both tracks are
   audible for `L` seconds (the render test proves it).
2. With the default toggles and crossfade turned on, a boundary between two
   albums crossfades (the #567 reporter's configuration and the default
   configuration both work).
3. With "keep gapless within albums" on, same-album boundaries stay gapless
   and unchanged.
4. At `crossfadeSeconds = 0`, output is bit-identical to today's gapless path.
5. Pause, resume, seek, stop, skip and an output device change during an
   overlap behave as defined under Slice 2b, item 11, and none leaves a
   stranded pump (the transport-gate regression tests still pass).
6. The play bar, Now Playing and history switch to the incoming track when
   its audio is first heard.
7. The node-volume ramps, the dead two-node ramps, and their tasks are gone.
8. `make lint`, `make test-audio-engine`, `make test-playback`,
   `make test-ui SWIFT_TEST_FLAGS="--skip UISnapshotTests"` (macOS 27),
   `make test-coverage`,
   and `make pseudolocale` all pass.

## Gotchas

- **The node is shared; the mix must not be.** Never schedule an incoming
  buffer on the node directly during an overlap, not even "just the first
  one". The node plays buffers in FIFO order, so a direct schedule plays
  after the outgoing tail, which is the bug this ADR removes.
- **`AVAudioFile` durations can be estimates** (VBR MP3 without a Xing
  header in particular). That is why the start is computed from
  `duration` but the end handles both an early and a late EOF. Do not
  "fix" the estimate by pre-scanning the file.
- **Early transition trap.** Firing `onTransition` when the first mixed
  buffer is *scheduled* repeats the ~0.8 s early switch of plain gapless.
  Fire it from the completion of the last unmixed buffer.
- **Actor reentrancy.** `armOverlap` is called from the engine while the
  pump's feed loop runs on its own executor. All overlap state lives in the
  pump actor; the engine never reads the pump's sources directly. See
  `docs/GOTCHAS.md`, "Transport operations stay behind the async-mutex gate".
- **Completion handlers retain.** The new completion handler that fires
  `onTransition` captures the pump weakly, as `claimSlotAndSchedule` already
  does, or a stopped pump lives as long as the node.
- **Clipping.** The mix is Float32 and may exceed 1.0 for two loud masters.
  Do not clamp in the mix; the limiter downstream handles it. Clamping in the
  mix would add distortion the limiter would have avoided.
- **ReplayGain later.** When ReplayGain is wired, per-track gain must be
  applied per source inside the mix (each `PumpSource` gets a linear gain),
  not in the shared `GainStage`, or one track's gain applies to the other
  during the overlap. Do not add that field in this ADR (no speculative
  fields); the ReplayGain issue adds it.
- **Podcast speed.** The TimePitch rate is global. Podcasts are excluded
  from crossfade by scope, so a rate change never applies to a music
  overlap; keep it that way if the scope ever widens.
- **`AVAudioFile.framePosition` after a failed read** raises an uncatchable
  exception (`docs/GOTCHAS.md`). The overlap reads two decoders; a failed
  read on either follows the existing `onError` path. Never rewind the
  outgoing decoder in a `defer` on a failure path.
- **Settings copy.** The existing slider already says "0 = sample-accurate
  gapless". Keep the 0 position meaning "off".

## Handoff

- **Branches.** One branch per slice, landed in order: slice 1 and 2a are
  `feat/` and `refactor/` with no user-visible change (`skip-changelog`),
  2b and 3 are `fix/`, and slice 4 lands with slice 3 if the maintainer
  prefers one user-visible PR. The fix PRs run /slice-review.
- **How to run the slices with a cheaper model.** One session per slice,
  in order. Prompt: "Implement slice N of
  `docs/design-spec/ADR-095-crossfade-overlap.md` on a new branch from main.
  Follow the slice exactly, including its commit subject. Run the module
  suites it names. Stop and ask if a Context7 lookup contradicts the spec."
  Slice 2b is the hard one: give it the strongest model available.
- **After the last slice:** add a `docs/GOTCHAS.md` entry, "Crossfade mixes
  inside the pump, never on the node", in the Problem / Rule / Why /
  Canonical file form, with `Graph/BufferPump.swift` as the canonical file,
  and mirror it to the project memory.
- **Follow-ups to file, not to build here:** ReplayGain is not applied at
  playback (see Non-goals); crossfade for Subsonic items; moving plain
  gapless to the exact transition moment.
