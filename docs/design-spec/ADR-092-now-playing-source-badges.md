# ADR-092: Now-Playing Source Badges

> Depends on: ADR-078 slice 5 (`StreamDetails` on the FFmpeg route), ADR-091 (channel layout label, one stereo fold), #522 (`FFmpegDecoder` keeps the file's own channels), #524 (`SampleRateLabel`).
> Binding docs: `_standards.md`; `localization.md`; the "Hover text" rule in `_standards.md`; the schema and testing sections of the root `CLAUDE.md`.
> Requested by the maintainer, 2026-09-15.

Written from measurements taken on a Mac running macOS 26 with FFmpeg 9.0.1
and TagLib 2.3.2. Every number below can be reproduced with the probes in
the Test plan.

Three slices, one branch (`feat/now-playing-badges`), one commit each, in
the order given. Slice 1 is the fact, slice 2 is the view, slice 3 is the
prose. Each stands on its own.

## Goal

The play bar says what is playing, as a row of small coloured boxes under
the title, artist and album: the codec, the bitrate, the sample rate, the
bit depth and the channel layout. Each box has hover text that says what
the value means. The title block sits at the top of the strip instead of
its vertical centre, so the row has room.

## Non-goals

- The mini player and the Immersive Mode cards. They have their own
  layouts and their own ADRs; the row is for the main window's strip.
- Get Info and the track panel. They already list these facts as rows
  (ADR-091 slice 4, #524); the badges are a glance, not a second listing.
- Clickable badges. A badge that filtered the library by codec or sorted
  by bitrate is a different feature with its own navigation contract.
- A Dolby Atmos badge. Where the FFmpeg route knows the profile it goes in
  the codec badge's hover text; the AVFoundation route does not know it
  (ADR-091 non-goals) and this ADR does not parse the `dec3` box.
- A "lossless" badge. `Track.isLossless` is already a table column, and
  the codec badge says the same thing to anyone who reads it.
- A DSD-specific rate label. A DSF track's stored sample rate is the DSD
  rate (2 822 400 Hz for DSD64) and `SampleRateLabel` renders it as
  "2822.4 kHz", which is true. "DSD64" is a nicety for later.
- Any schema change. Every value the row shows is already a column or a
  fact the open decoder has.

## Outcome shape

Slice 1, the fact:

- `Modules/AudioEngine/Sources/AudioEngine/Decoder/Decoder.swift` (`codec` requirement with a default)
- `Modules/AudioEngine/Sources/AudioEngine/Decoder/AVFoundationDecoder.swift` (`codec` from the file's format ID)
- `Modules/AudioEngine/Sources/AudioEngine/Decoder/FFmpegDecoder.swift` (`codec` from `streamDetails`)
- `Modules/AudioEngine/Sources/AudioEngine/Transport.swift` (`currentCodec`, default nil)
- `Modules/AudioEngine/Sources/AudioEngine/AudioEngine+StreamDetails.swift` (`currentCodec`)
- `Modules/Playback/Sources/Playback/QueuePlayer.swift` (`currentCodec` forwarded)
- `Modules/UI/Sources/UI/ViewModels/NowPlayingSourceFacts.swift` (new: the value type and its merge rule)
- `Modules/UI/Sources/UI/ViewModels/NowPlayingViewModel.swift` (publishes `sourceFacts`)
- `Modules/AudioEngine/Tests/AudioEngineTests/DecoderCodecTests.swift` (new)
- `Modules/UI/Tests/UITests/ViewModelTests/NowPlayingSourceFactsTests.swift` (new)
- `docs/design-spec/README.md` (index row)

Slice 2, the row:

- `Modules/UI/Sources/UI/AppRoot/SourceBadgesRow.swift` (new: the row, one badge view, the codec display mapping, the hover copy)
- `Modules/UI/Sources/UI/AppRoot/NowPlayingStrip.swift` (top-aligned info block, the row added)
- `Modules/UI/Sources/UI/Theme/Colours.swift` (five badge tints)
- `Modules/UI/Sources/UI/Resources/Localizable.xcstrings` (labels and hover copy, then `make pseudolocale`)
- `Modules/UI/Tests/UITests/ViewModelTests/ContrastTests.swift` (ten cases: five tints, two modes)
- `Modules/UI/Tests/UITests/ViewModelTests/SourceBadgesRowConventionTests.swift` (new)
- `Modules/UI/Tests/UITests/SnapshotTests/SnapshotTests.swift` and `SnapshotTests+HighContrast.swift` (a with-facts case; five references re-recorded)
- `Modules/UI/Tests/UITests/SnapshotTests/__Snapshots__/` (the re-recorded images)

Slice 3, the prose:

- `CHANGELOG.md`, `README.md` (feature bullet), `website/src/_data/features.json`

## What carries over from previous specs

- ADR-078 slice 5 gave the FFmpeg route `StreamDetails` (container, codec,
  profile, sample rate, channels, claimed bitrate) and `Transport` a
  `currentStreamDetails` seam with a default of nil so fakes need not
  implement it. `currentCodec` copies that shape exactly.
- ADR-091 slice 4 gave the UI `ChannelLayoutLabel` (Mono, Stereo, 5.1,
  7.1, else a count) with the surround hover text, and #524 gave it
  `SampleRateLabel`. The badges reuse both; no new formatter.
- #522 made `FFmpegDecoder.sourceFormat` carry the file's own channels, so
  the engine's `sourceFormat` says the same thing on both routes.
- The UI rule for strings owned by lower modules: the codec name is a raw
  identifier from `AudioEngine`; the UI maps it to a display name and
  localizes only the hover copy.
- The hover-text rule: badges are not controls, so the audit does not
  require `.help()`; the feature does, and the copy obeys localization.
- Snapshot references live in the repository and are re-recorded with one
  `SNAPSHOT_TESTING_RECORD=all` run; the recorded images are part of the
  slice's commit, and the reviewer looks at them.

## Implementation plan

### Facts the plan rests on (measured 2026-09-15)

1. `AVAudioFile.fileFormat.settings[AVFormatIDKey]` names the codec for
   every file the AVFoundation route opens: `lpcm` for WAV and AIFF,
   `flac`, `.mp3`, `aac `, `alac`, `ec-3` for E-AC-3 raw or in MP4. Its
   `streamDescription.mBitsPerChannel` is 16 for PCM and 0 for every
   compressed codec, so bit depth cannot come from the decoder.
2. `FFmpegDecoder.streamDetails.codec` is FFmpeg's short name (`opus`,
   `vorbis`, `truehd`, `eac3`, `dsd_lsbf_planar`, `mp3`) and
   `codecProfile` carries "Dolby Digital Plus + Dolby Atmos" where a file
   has it (ADR-091 facts).
3. `Track` carries `fileFormat` (the extension), `bitrate` (kbps, TagLib's
   average), `sampleRate`, `bitDepth` (lossless containers only, #405) and
   `channelCount`. `NowPlayingViewModel.currentTrack` holds it for a local
   track and is nil for a Subsonic stream, a podcast or internet radio.
4. For a stream, `QueuePlayer.currentStreamDetails` is the only source of
   rate, channels and bitrate; `RadioStationInfoSheet` already reads it
   through `LibraryViewModel+Radio`.
5. `Transport` declares `currentStreamDetails` with a protocol-extension
   default of nil (`Transport.swift:41` and `:48`), and four test fakes
   conform to `Decoder` without it. A new requirement on either protocol
   needs the same default or every fake changes.
6. `NowPlayingStrip` is 407 lines under a 500-line lint limit. Its info
   block is a `VStack(alignment: .leading, spacing: 2)` of the title
   (`Typography.body`), the artist and album line (`Typography.subheadline`)
   and an optional chapter or CUE marker caption, inside an `HStack` that
   centres it vertically in `Theme.nowPlayingStripHeight` of 72 pt.
7. Five strip snapshots exist: idle light and dark, with-track light, high
   contrast light and dark. The with-track case seeds a `Track` with only
   `fileFormat: "flac"`, so today it would show a codec badge and nothing
   else.
8. `ContrastTests` asserts ratios with `ContrastAudit` per token and mode:
   4.5 for text tokens, 3.0 for `ratingFill`, `lovedTint`, `accentColor`
   and `warningTint` against `bgPrimary`. New tints follow the 3.0 rule
   as non-text components (WCAG 1.4.11), against both backgrounds.

### Slice 1: the fact

1. `Decoder`: add `var codec: String? { get }` with a protocol-extension
   default of nil, so the four fakes stay as they are. The value is
   FFmpeg's short name for the codec family, so both routes speak one
   vocabulary: `AVFoundationDecoder` maps its format ID (`lpcm` to `pcm`,
   `flac`, `.mp3` to `mp3`, `aac ` to `aac`, `alac`, `ec-3` to `eac3`,
   `ac-3` to `ac3`, `opus`; anything else to the trimmed lowercase
   four-character code); `FFmpegDecoder` returns `streamDetails.codec`.
2. `Transport`: add `var currentCodec: String? { get async }` with a
   default of nil, next to `currentStreamDetails`. `AudioEngine` returns
   `decoder?.codec`; `QueuePlayer` forwards to the engine.
3. `NowPlayingSourceFacts` (UI module, a `Sendable` struct): `codec`,
   `codecProfile`, `bitrateKbps`, `sampleRateHz`, `bitDepth`,
   `channelCount`, each optional, plus `init(track:)` and
   `init(details:codec:)` and `merging(_:)` with one rule: the engine's
   live fact wins where it exists, the track's column fills the rest. Bit
   depth only ever comes from the track (fact 1).
4. `NowPlayingViewModel`: publish `public private(set) var sourceFacts:
   NowPlayingSourceFacts?`. `setCurrentTrack` seeds it from the track;
   the existing engine-driven current-item path refreshes it with
   `currentCodec` and `currentStreamDetails` once the decoder is open;
   `applyStreamItem` builds it from the details alone; the clear path nils
   it. Nothing new is observed: the refresh rides the task that already
   reacts to the engine's current item.
5. No display mapping here. The view model carries raw names; slice 2
   maps them.

### Slice 2: the row

1. `SourceBadgesRow`: an `HStack(spacing: 6)` of up to five `SourceBadge`
   views in the fixed order codec, bitrate, sample rate, bit depth,
   channels; a badge whose value is nil is not drawn, so the row shrinks
   rather than showing a dash. Empty facts draw nothing. Each badge is a
   `Text` in `Typography.caption2` (or the nearest existing caption
   token), `Color.textPrimary`, in a capsule with the tint at 14% opacity
   as fill and the tint at full strength as a 1 pt border. Under
   increase-contrast the fill goes and the border becomes 1.5 pt, through
   the existing `HighContrastModifier` pattern.
2. Values: codec through a UI-side display mapping (`flac` "FLAC", `alac`
   "ALAC", `aac` "AAC", `mp3` "MP3", `mp2` "MP2", `pcm` "PCM", `opus`
   "Opus", `vorbis` "Vorbis", `eac3` "E-AC-3", `ac3` "AC-3", `truehd`
   "TrueHD", `dts` "DTS", `dsd_lsbf_planar` and `dsd_msbf_planar` "DSD",
   `wavpack` "WavPack", `ape` "APE", `musepack` "Musepack", `tta` "TTA",
   `wmav2` and `wmapro` "WMA"; anything else the raw name uppercased);
   bitrate through the existing `%lld kbps` key; sample rate through
   `SampleRateLabel`; bit depth through the existing `%lld-bit` key;
   channels through `ChannelLayoutLabel`.
3. Hover text, one string per badge, localized, saying what the value is
   and not what it reads: codec "How the audio is stored in the file. The
   name of the compression, or PCM for none." (with the Atmos profile
   sentence appended when `codecProfile` carries it, and the surround
   sentence from `ChannelLayoutLabel.help` reused on the channels badge);
   bitrate "How much data the file spends per second of sound. Higher is
   more detail for a lossy codec; for a lossless one it only follows the
   music."; sample rate "How many samples per second the file holds.
   44.1 kHz is CD; higher rates carry more of the top end."; bit depth
   "How finely each sample is measured. 16 bits is CD; 24 bits gives more
   headroom and a lower noise floor."; channels from
   `ChannelLayoutLabel.help(for:)`.
4. Accessibility: the row is one element (`accessibilityElement(children:
   .combine)`) whose label lists the facts in order ("FLAC, 1411 kbps,
   44.1 kHz, 16-bit, Stereo"), so VoiceOver reads it once. No
   `.updatesFrequently`: the facts change once per track.
5. Colours: five tokens in `Colours.swift` with adaptive light and dark
   values, chosen away from the existing accent, rating, loved and warning
   hues. Starting values, to be adjusted until `ContrastTests` passes:
   `badgeCodec` blue (light 0.16, 0.42, 0.78; dark 0.45, 0.68, 1.00),
   `badgeBitrate` green (light 0.10, 0.52, 0.30; dark 0.36, 0.80, 0.55),
   `badgeSampleRate` teal (light 0.06, 0.50, 0.55; dark 0.30, 0.78, 0.82),
   `badgeBitDepth` purple (light 0.48, 0.28, 0.72; dark 0.72, 0.58, 0.98),
   `badgeChannels` magenta (light 0.70, 0.18, 0.50; dark 0.95, 0.50, 0.78).
   Each tint at full strength must reach 3.0 against `bgPrimary` and
   `bgSecondary` in both modes; `textPrimary` on the 14% fill must stay at
   4.5, which the audit also asserts.
6. Layout: the info block moves to the top of the strip. Give the `VStack`
   `.frame(maxHeight: .infinity, alignment: .top)` and `.padding(.top,
   6)`, and the row as its last child with `.padding(.top, 2)`. Measure
   in the with-facts snapshot: title, subtitle, a marker caption and the
   row must all fit in 72 pt without clipping. Only if they clip, raise
   `Theme.nowPlayingStripHeight` to 80 and re-record every strip snapshot;
   say so in the commit.
7. The strip stays under 500 lines: the row, the badge, the mapping and
   the copy live in `SourceBadgesRow.swift`; the strip gains about ten
   lines.
8. `make pseudolocale` after the catalog changes; `make generate` for the
   new test file; the snapshots re-recorded once and committed.

### Slice 3: the prose

1. `CHANGELOG.md` under Unreleased, for listeners: the play bar now shows
   the codec, bitrate, sample rate, bit depth and channels of what is
   playing, as small coloured boxes under the title, each with a hover
   explanation.
2. `README.md`: one bullet under the player features; `website/src/_data/
   features.json`: one sentence where the player is described.

## Behavioural definitions and contracts

- **Codec vocabulary.** `Decoder.codec` is FFmpeg's short codec name on
  both routes, or nil when the decoder cannot say. The same file gives the
  same name through either decoder: a raw E-AC-3 and an E-AC-3 in MP4
  both say `eac3`.
- **Merge rule.** In `NowPlayingSourceFacts`, a live engine fact replaces a
  track column; a nil live fact leaves the column. Bit depth is only ever
  the track's.
- **Row shape.** The row draws one badge per non-nil fact, in the fixed
  order codec, bitrate, sample rate, bit depth, channels, and nothing at
  all when every fact is nil or nothing is playing.
- **Hover.** Every drawn badge has localized hover text explaining the
  fact, not repeating the value.
- **Contrast.** Every tint reaches 3.0 against both backgrounds in both
  modes, asserted by `ContrastTests`; `textPrimary` on the fill reaches 4.5.
- **Layout.** With a title, a subtitle, a marker caption and five badges,
  nothing clips in the strip's height.
- **Streams.** A Subsonic stream, a podcast and an internet radio station
  show the facts the decoder reports (codec, rate, channels, claimed
  bitrate) and no bit depth.

## Context7 lookups

Apple's AVFoundation is not on Context7; fact 1 was measured with the probe
in the Test plan. Look up:

- `swift-testing` parameterized tests, for the contrast cases and the codec
  mapping table.
- `swift-snapshot-testing` for the record mode variable and precision
  arguments, to re-record the five strip references without loosening the
  others.

Use the latest version of each library in the lookup, per the root
`CLAUDE.md` rule.

## Dependencies

- Slice 2 depends on slice 1 (`sourceFacts`).
- Slice 3 depends on slice 2 (it describes it).
- No new packages, pins or Homebrew additions.

## Test plan

The probe that produced fact 1 (a Swift script; run it against the
AudioEngine fixtures):

```
import AVFoundation
let file = try AVAudioFile(forReading: url)
let id = file.fileFormat.settings[AVFormatIDKey] as? UInt32
let bits = file.fileFormat.streamDescription.pointee.mBitsPerChannel
```

Slice 1:

- `DecoderCodecTests`: `AVFoundationDecoder.codec` is `pcm` for the WAV
  and the AIFF, `flac`, `mp3`, `aac`, `alac`, and `eac3` for E-AC-3 in
  MP4 and raw; `FFmpegDecoder.codec` is `vorbis` for the Ogg, `opus`,
  `wavpack`, `eac3` for the raw E-AC-3, `truehd`, `dsd_lsbf_planar`.
- `NowPlayingSourceFactsTests`: `init(track:)` copies the five columns;
  `merging` lets a live codec and rate win and keeps the track's bit
  depth; all-nil facts report `isEmpty`.
- A `NowPlayingViewModel` test through the existing `MockTransport`:
  `setCurrentTrack` seeds `sourceFacts` from the track; clearing the
  display nils it.

Slice 2:

- `ContrastTests`: ten cases, five tints by two modes, each at 3.0 against
  `bgPrimary` and `bgSecondary`; `textPrimary` against each 14% fill at
  4.5 in both modes.
- `SourceBadgesRowConventionTests`: the codec mapping table (`flac` to
  "FLAC", `eac3` to "E-AC-3", an unknown name to its uppercase); the row
  draws no badge for a nil fact and none for empty facts (a view-model
  level assertion on the badge list the row derives, kept as a pure
  function so it is testable host-less); every badge carries `.help(`;
  the strip's info block carries `alignment: .top`.
- Snapshots: a new with-facts light case seeding all five values, plus the
  five existing strip references re-recorded; the reviewer checks the
  images in the PR.
- `make pseudolocale` passes; `Scripts/audit-help-text.py` passes.

Slice 3: the changelog check on the PR.

All slices: `make format`, `make lint`, `make build`, `make test-coverage`,
`make test-audio-engine` and `make test-playback` (slice 1), `make test-ui`
(slices 1 and 2), then `/slice-review` and the PR.

## Acceptance criteria

Slice 1:

- Playing a FLAC, the view model's `sourceFacts` reads `flac`, the file's
  bitrate, rate, bit depth and channels. Playing a raw E-AC-3, it reads
  `eac3` with six channels and no bit depth. Playing internet radio, it
  reads the stream's codec, rate, channels and claimed bitrate.

Slice 2:

- The strip shows the five boxes under the title for a local FLAC, four
  for an MP3 (no bit depth), and the stream's boxes for radio; each has a
  different colour and a hover explanation; nothing clips with a CUE
  marker line showing; the idle strip is unchanged apart from the title
  block sitting higher.
- `ContrastTests` and the snapshots pass; `make pseudolocale` is green.

Slice 3:

- The changelog note reads for a listener; README and the website mention
  the row.

## Gotchas

- **Bit depth never comes from the decoder.** `mBitsPerChannel` is 0 for
  every compressed codec (fact 1). Only the track column has it, and only
  for lossless containers (#405).
- **The file extension is not the codec.** `Track.fileFormat` says `m4a`
  for AAC, ALAC and E-AC-3 alike. The codec badge must come from the
  decoder or it lies for Dolby in MP4 (#529).
- **`NowPlayingStrip` is near the lint limit.** Nothing but the row's
  call site and the alignment change goes in that file.
- **Snapshots are recorded, not tolerated.** Do not raise a precision
  argument to make a changed strip pass; re-record the reference and let
  the reviewer look at it.
- **Hover text obeys localization.** Every `.help(` string goes through
  `L10n.string` with a catalog key, then `make pseudolocale`, or the en-XA
  coverage test fails.
- **Colour choices are measured.** A tint that reads well in light mode
  can fail 3.0 in dark mode against `bgSecondary`; run `ContrastTests`
  before judging by eye, and adjust the dark value independently.
- **The transport fakes.** `MockTransport` in the UI tests and the
  `Decoder` fakes in the AudioEngine tests conform without the new
  members; keep the protocol-extension defaults or every fake changes.

## Handoff

Run each slice in its own session on the branch `feat/now-playing-badges`,
from the commit that carries this ADR. Paste the prompt, then the whole of
this file.

Slice 1 prompt:

> Implement slice 1 of docs/design-spec/ADR-092-now-playing-source-badges.md
> on the branch feat/now-playing-badges. Start with DecoderCodecTests so the
> codec vocabulary is fixed before the plumbing. Follow the root CLAUDE.md
> gates and the AudioEngine, Playback and UI module testing rules. Do not
> touch slices 2 or 3. Commit when green; do not push.

Slice 2 prompt:

> Implement slice 2 of docs/design-spec/ADR-092-now-playing-source-badges.md
> on the branch feat/now-playing-badges, after slice 1. Start with
> ContrastTests and the five tints so the colours are settled before the
> view. Keep NowPlayingStrip under 500 lines. Re-record the strip snapshots
> once and commit the images. Run make pseudolocale. Commit when green; do
> not push.

Slice 3 prompt:

> Implement slice 3 of docs/design-spec/ADR-092-now-playing-source-badges.md
> on the branch feat/now-playing-badges, after slice 2. Prose only: the
> changelog note for listeners, the README bullet, the website feature
> sentence. Then run /slice-review and open the PR.
