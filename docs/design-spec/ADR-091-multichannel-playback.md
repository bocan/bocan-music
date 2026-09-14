# ADR-091: Multichannel Playback

> Depends on: ADR-013 (DSP chain and ReplayGain), ADR-078 slice 5 (stream details on the FFmpeg route).
> Binding docs: `_standards.md`; `localization.md` (slice 4); the schema and testing sections of the root `CLAUDE.md`.
> Requested by the maintainer, 2026-09-13, from #513 and #515.

Written from measurements taken on a Mac running macOS 26 with FFmpeg 9.0.1,
not from reading alone. Every number below can be reproduced with the probe
recipe in the Test plan.

Four slices, one branch and one PR each, in the order given. Slice 1 is the
fix and closes #515. Slices 2 to 4 each stand on their own and can wait.

## Goal

A multichannel file (5.1 ALAC, AAC, FLAC, WAV, E-AC-3, TrueHD, with or
without Atmos metadata) plays in Bòcan with every channel audible, folded to
stereo, instead of stopping with an error or playing the front pair only.
Its loudness is measured from what is heard. Raw Dolby files reach the
library. The UI says what the file is and what Bòcan does with it.

## Non-goals

- Rendering Atmos objects. FFmpeg and AudioToolbox both decode the bed and
  discard the object layer. There is no lawful decoder to add. The UI says
  so instead of implying otherwise.
- Bitstream passthrough to an AVR over HDMI. That is a second output engine
  outside `AVAudioEngine` (encoded HAL stream formats, hog mode, no DSP, no
  volume, no visualizer, no crossfade, no gapless). File it as an
  enhancement with that scope written on it; do not start it here.
- Spatialising through `AVSampleBufferAudioRenderer` or
  `AVAudioEnvironmentNode`. A later feature, not this work.
- Dolby's own downmix coefficients on the FFmpeg route (the `downmix` codec
  option on ac3, eac3 and truehd). Measured on the surround-only fixture:
  swresample's default fold gives a mean of −13.9 dB, the decoder-side Dolby
  fold gives −21.6 dB. That is a loudness and taste decision, and it would
  desynchronise playback loudness from the ReplayGain measurement in slice
  2, which uses the AVFoundation fold. Decide it with a listening test in
  its own issue, default off.
- Raw TrueHD (`.thd`, `.mlp`) in the scanner. `AVAudioFile` refuses TrueHD
  (`kAudioFileUnsupportedFileTypeError`), so the slice 3 property fallback
  cannot read it, and TagLib has no TrueHD type. TrueHD inside Matroska
  (`.mka`, `.mkv`) already scans and plays through FFmpeg.
- An Atmos badge on MP4 files. On the AVFoundation route nothing exposes the
  profile; it would need the `dec3` box parsed at scan time. On the FFmpeg
  route `StreamDetails.codecProfile` already says "Dolby Digital Plus +
  Dolby Atmos" for free. Show it where it exists; do not build the parser.
- Any schema change. `tracks.channel_count` exists and is written by the
  importer (`Modules/Library/Sources/Library/TrackImporter.swift:170`).

## Outcome shape

Slice 1, `fix/515-multichannel-fold`:

- `Modules/AudioEngine/Sources/AudioEngine/Graph/BufferPump.swift` (the converter decision and its doc comment)
- `Modules/AudioEngine/Sources/AudioEngine/Internal/FormatConverter.swift` (`downmix`, and the conditional default layout)
- `Modules/AudioEngine/Sources/AudioEngine/Decoder/DecoderFactory.swift` (the `decoder.selected` log line)
- `Modules/AudioEngine/Tests/AudioEngineTests/BufferPumpFormatTests.swift` (new)
- `Modules/AudioEngine/Tests/AudioEngineTests/FormatConverterFoldTests.swift` (new)
- `Modules/AudioEngine/Tests/AudioEngineTests/AVFoundationDecoderTests.swift` (one end-to-end case)
- `Scripts/gen-audio-fixtures.sh` and the checked-in fixtures it adds
- `CHANGELOG.md`

Slice 2, `fix/multichannel-replaygain`:

- `Modules/AudioEngine/Sources/AudioEngine/ReplayGain/ReplayGainAnalyzer.swift`
- `Modules/AudioEngine/Tests/AudioEngineTests/ReplayGainAnalyzerTests.swift` (or the existing suite)
- `CHANGELOG.md`

Slice 3, `feat/raw-dolby-files`:

- `Modules/Metadata/Sources/Metadata/TagReader.swift` (extension list, fallback call)
- `Modules/Metadata/Sources/Metadata/AVFoundationProperties.swift` (new: properties for files TagLib cannot parse)
- `Modules/Metadata/Tests/MetadataTests/TagReaderFallbackTests.swift` (new)
- `Modules/AudioEngine/Sources/AudioEngine/Decoder/DecoderFactory.swift` (the `.m4a` fallback)
- `Modules/AudioEngine/Tests/AudioEngineTests/DecoderFactoryTests.swift` (routing cases)
- `Modules/Metadata/Tests/MetadataTests/Fixtures/` and `Scripts/gen-audio-fixtures.sh`
- `CHANGELOG.md`, `README.md` (format list), `website/` (format list)

Slice 4, `feat/channel-count-info`:

- `Modules/UI/Sources/UI/Common/TrackInfoPanel.swift`
- `Modules/UI/Sources/UI/MetadataEditor/TagEditorSheet+InfoTabs.swift`
- `Modules/UI/Sources/UI/Resources/Localizable.xcstrings`
- `docs/data-dictionary-notes.json` and the regenerated `docs/data-dictionary.md`
- `Modules/UI/Tests/UITests/` (a snapshot or a view-model test for the label)
- `CHANGELOG.md`

## What carries over from previous specs

- #387 gave `DecoderFactory` its FLAC and AIFF fallback to FFmpeg. Slice 3
  copies that shape to `.m4a` exactly; do not invent a new one.
- #497 set the rule that the caller is told AVFoundation's reason and the
  log gets FFmpeg's. Keep it.
- ADR-078 slice 5 added `StreamDetails` (codec, profile, channels) on the
  FFmpeg route. Slice 4 reads it; nothing new is captured.
- #481 decided a cover-art persist failure propagates rather than being
  swallowed. Same policy for a converter that cannot be built: propagate as
  `formatConversionFailure`, never play the wrong thing quietly.
- The audio fixture rule: generated by `Scripts/gen-audio-fixtures.sh`,
  checked in, never generated at test time. Keep each new fixture a quarter
  of a second so the ALAC stays under 100 kB.

## Implementation plan

### Facts the plan rests on (measured 2026-09-13)

Fixtures were 5.1 at 48 kHz with a 440 Hz tone in Ls and Rs only and digital
silence in L, R, C and LFE.

1. `AVAudioFile` opens 5.1 ALAC, AAC, FLAC, WAV and E-AC-3, in MP4 and raw.
   It refuses TrueHD. Every one carries a real channel layout tag
   (`0x7C0006` MPEG_5_1_D for ALAC and AAC in MP4, `0x7B0006` MPEG_5_1_C for
   E-AC-3, `0xBB0006` WAVE_5_1_A for FLAC and WAV). The channel order differs
   by container, so "channel 0 and 1" is not "left and right" in general.
2. `AVAudioConverter` from 6 channels to stereo with `downmix == false`, the
   default and what `FormatConverter` uses today, produces L = R = 0.000 RMS
   from that source. With `downmix == true` it produces L = R = 0.104. This is
   the "surround channels are muted" symptom in #513.
3. `AVAudioFile.read(into:)` with a stereo buffer for a 6-channel file
   returns a catchable error (`-50`, `ExtAudioFileRead`) on macOS 26. It does
   not raise an Objective-C exception. `AVFoundationDecoder.read` wraps it as
   `decoderFailure`, the pump reports it, the engine emits `.failed`, and the
   song stops with an error. That is #515 as it actually behaves on Tahoe.
4. Today `BufferPump.init` (`BufferPump.swift:108`) builds the converter on
   sample rate alone. So one path, two outcomes: rate matches the device,
   no converter, the read fails; rate differs, converter built, surrounds
   dropped.
5. The FFmpeg route is not affected. `FFmpegDecoder.buildSWR` folds to
   stereo with the codec's own layout as input; swresample builds a proper
   matrix. Mean −13.9 dB from the surround-only E-AC-3.
6. `ReplayGainAnalyzer.readSamples` (`ReplayGainAnalyzer.swift:114`) takes
   channels 0 and 1 of the file's own format. For the MP4 layout that is
   Centre and Left. Every multichannel file gets a wrong loudness value.
7. The scanner skips any file TagLib cannot parse (`ScanCoordinator.swift:331`,
   `scan.tag_read_failed`). TagLib has no AC-3, E-AC-3 or TrueHD type, so
   the `.ac3` entry already in `TagReader.supportedExtensions` almost
   certainly imports nothing today. Slice 3 verifies that first.
8. `Track.channelCount` is written by the importer and shown nowhere.
9. Nothing logs which decoder a file was given. Neither the maintainer nor a
   reporter can tell an AVFoundation failure from an FFmpeg one.

### Slice 1: the stereo fold (closes #515, the muting half of #513)

1. `BufferPump.init`: build the converter when the source differs from the
   output in sample rate **or** channel count. Keep `pumpFormat` equal to the
   source format whenever a converter exists, so the decoder always reads
   into a buffer of its own format. Rewrite the doc comments on
   `pumpFormat` and `converter` (lines 42 to 51), which currently say the
   converter exists only for a rate mismatch.
2. `FormatConverter.init`: set `downmix = true` on the `AVAudioConverter`
   right after it is created. That is the whole muting fix.
3. Default layout, only if needed: write the test in the Test plan that
   builds a converter from a 6-channel source format with no channel layout.
   If `AVAudioConverter` accepts it and the fold is audible, stop; no code.
   If it returns nil or folds to silence, add a helper that maps a channel
   count to a default tag (3 → MPEG_3_0_A, 4 → Quadraphonic, 5 → MPEG_5_0_A,
   6 → MPEG_5_1_A, 7 → MPEG_6_1_A, 8 → MPEG_7_1_A) and apply it to the
   decoder's `sourceFormat` **before** the pump allocates its buffers, so
   buffer and converter carry the same format object. Do not relabel only
   the converter side; `AVAudioConverter.convert` checks the input buffer's
   format against its own.
4. `DecoderFactory.make(for:)`: after the decoder is built, log
   `decoder.selected` at debug with the decoder type name, codec, channel
   count, sample rate and layout tag (hex, or "none"). One line, one place.
5. Fixtures: extend `Scripts/gen-audio-fixtures.sh` with a quarter-second
   5.1 group, tone in Ls and Rs only, using this lavfi source:
   `aevalsrc=0|0|0|0|0.5*sin(440*2*PI*t)|0.5*sin(440*2*PI*t):c=5.1:s=48000:d=0.25`.
   Emit `surround-lsrs-48000.m4a` (ALAC), `surround-lsrs-44100.flac`
   (change `s=` to 44100), `surround-lsrs-48000.eac3` (raw E-AC-3, `-c:a
   eac3`), `surround-lsrs-48000.thd` (`-c:a truehd -strict -2`), and
   `surround-lsrs-eac3-48000.m4a` (`-c:a eac3 -f mp4`; the default ipod
   muxer refuses eac3, so `-f mp4` is required). Also a front-only twin of
   the ALAC, tone in L and R, silence elsewhere, for slice 2.
6. `CHANGELOG.md` under Unreleased, for listeners: multichannel songs play
   with every channel folded into stereo instead of stopping or losing the
   surrounds; Bòcan does not render Atmos objects, it plays the mix as
   stereo.

### Slice 2: loudness on multichannel

1. `ReplayGainAnalyzer.readSamples`: when the file's `processingFormat` has
   more than two channels, fold each chunk to stereo at the file's own
   sample rate with `FormatConverter` (which now carries `downmix`), then
   take L and R from the folded buffer. Mono keeps the existing duplicate.
   Stereo is untouched.
2. Do not implement BS.1770 multichannel weighting. It measures the bed;
   Bòcan plays the fold, and the fold is what a listener hears at the volume
   Bòcan sets. Say so in a comment where the fold happens.
3. Do not touch stored values. `CHANGELOG.md`: multichannel songs get a
   correct ReplayGain value the next time they are analysed; values measured
   before this release for such songs were wrong.

### Slice 3: raw Dolby files reach the library, and `.m4a` gets a fallback

1. First, confirm fact 7 with a raw `.ac3` fixture through
   `TagReader.read`. Record the result in the PR body.
2. `TagReader.supportedExtensions`: add `eac3` and `ec3`. Leave `thd` and
   `mlp` out (see Non-goals).
3. `TagReader.read`: when TagLib throws **and** the extension is `ac3`,
   `eac3` or `ec3`, build the `TrackTags` from `AVAudioFile` instead: title
   is the filename without extension, `duration` is `length / sampleRate`,
   `sampleRate` and `channels` from `processingFormat`, `bitDepth` nil,
   everything else nil, no cover art. Put the AVFoundation read in its own
   small type (`AVFoundationProperties`) so `TagReader` stays a TagLib
   reader with one named escape hatch. If `AVAudioFile` also refuses,
   rethrow the original TagLib error unchanged.
4. `DecoderFactory.make(codec:url:)`: move `.m4a` from the plain
   AVFoundation case into the FLAC and AIFF case, so it gets the same
   fallback, the same `accessDenied` and `fileNotFound` short-circuits, and
   the same #497 logging. Nothing else changes.
5. Routing tests for the raw fixtures: `.eac3` sniffs as `.ac3` (sync word
   `0x0B77`) and goes to FFmpeg; `.thd` sniffs as `.unknown` and reaches
   FFmpeg through the last-resort branch. Both must open and report six
   channels in `streamDetails`.
6. A fallback test for `.m4a` needs a file `AVAudioFile` refuses and FFmpeg
   opens. Try Opus in MP4 (`-c:a libopus -f mp4`) first; if AudioToolbox
   turns out to open it, use FLAC in MP4 (`-c:a flac -strict -2 -f mp4`).
   Record which one was needed in the test's comment.
7. `README.md` and the website's format list gain E-AC-3. `CHANGELOG.md`:
   Dolby Digital Plus files with no container are now found by a library
   scan and play.

### Slice 4: say what the file is

1. `TrackInfoPanel.swift` (around line 107) and `TagEditorSheet+InfoTabs.swift`
   (around line 18): add a "Channels" row next to bit depth and sample
   rate, from `track.channelCount`. Display mapping: 1 "Mono", 2 "Stereo",
   6 "5.1", 8 "7.1", anything else "N channels". Nil shows nothing, like
   bit depth does.
2. Hover text on the row, localized, that says the mix plays as stereo and
   that Atmos objects are not rendered. The row is not a control, so this is
   a `.help()` on the content; the help-text audit does not require it, the
   honesty does.
3. Where the FFmpeg route's `StreamDetails.codecProfile` is already surfaced
   for a playing track, show it unchanged. Do not plumb it anywhere new.
4. All strings through `L10n`, keys in `Localizable.xcstrings`, then
   `make pseudolocale`.
5. `docs/data-dictionary-notes.json`: `tracks.channel_count` gains the two
   views under "read by"; run `make data-dictionary`.
6. `CHANGELOG.md`: Get Info and the track panel now show the channel count,
   and say that surround mixes play as stereo.

## Behavioural definitions and contracts

- **Converter decision.** A `BufferPump` has a converter if and only if
  `decoder.sourceFormat` differs from `outputFormat` in sample rate or
  channel count. When it has one, `pumpFormat == decoder.sourceFormat`.
- **Fold.** For a source with more than two channels, the stereo output of
  `FormatConverter.convert` is not silent when any source channel is not
  silent. Surround channels contribute to both L and R.
- **Failure.** If a converter cannot be built for a source, `BufferPump.init`
  throws `formatConversionFailure`. The pump never reads into a buffer whose
  format is not the decoder's.
- **Loudness.** `ReplayGainAnalyzer.analyze` measures the same signal the
  engine would play: the stereo fold for more than two channels.
- **Scanner.** A raw `.eac3` or `.ec3` file with no tags imports with its
  filename as title and real duration, sample rate and channel count.
- **Routing.** A `.m4a` that AVFoundation refuses for a reason other than
  access or a missing file is offered to FFmpeg before the refusal is
  reported.
- **Log.** Every decoder built through `DecoderFactory.make(for:)` produces
  one `decoder.selected` debug line naming the decoder, codec, channels,
  rate and layout.
- **UI.** A track with a known channel count shows it in Get Info and the
  track panel; the hover text says the mix is played as stereo.

## Context7 lookups

Apple's AVFoundation is not on Context7; the behaviour of
`AVAudioConverter.downmix` and `AVAudioFile.read(into:)` above was measured,
not read, and the probe in the Test plan is the reference. Look up:

- `swift-testing` for `#expect` with a tolerance on floating point values
  and for `withKnownIssue` semantics if a test must be conditional. Do not
  add a permanent known issue (see #518).
- FFmpeg 9 `libswresample` (`swr_alloc_set_opts2`, rematrixing with an
  `AV_CHANNEL_ORDER_UNSPEC` input layout) only if slice 3 finds a raw
  fixture whose codec context lacks a native layout.

Use the latest version of each library in the lookup, per the root
`CLAUDE.md` rule.

## Dependencies

- Slice 2 depends on slice 1 (`FormatConverter.downmix`).
- Slice 3 depends on nothing in slice 1, but its `.m4a` routing test is
  only meaningful once slice 1 makes multichannel MP4 play.
- Slice 4 depends on nothing; it reads a column that already exists.
- All slices: `ffmpeg` and `sox` from Homebrew for `gen-audio-fixtures.sh`;
  FFmpeg 9 provides `eac3` and `truehd` encoders (checked with
  `ffmpeg -encoders`).

## Test plan

The probe that produced the numbers, for re-checking any claim:

```
SRC='aevalsrc=0|0|0|0|0.5*sin(440*2*PI*t)|0.5*sin(440*2*PI*t):c=5.1:s=48000:d=1'
ffmpeg -f lavfi -i "$SRC" -c:a alac surround-alac.m4a
ffmpeg -f lavfi -i "$SRC" -c:a eac3 -f mp4 surround-eac3.m4a
ffmpeg -f lavfi -i "$SRC" -c:a eac3 surround.eac3
ffmpeg -f lavfi -i "$SRC" -c:a truehd -strict -2 surround.thd
```

Then a Swift script that opens each with `AVAudioFile`, prints
`processingFormat` (channels, rate, `channelLayout?.layoutTag`), reads one
buffer in that format, prints RMS per channel, and converts to stereo with
`AVAudioConverter` at `downmix` false and true, printing L and R RMS.

Slice 1:

- `BufferPumpFormatTests`: a fake decoder with a 6-channel source format at
  44100 and an output format of stereo 44100. Assert the pump has a
  converter and `pumpFormat.channelCount == 6`. Same with rates 48000 and
  44100. Same with stereo at the same rate: no converter. Uses the existing
  fake-decoder pattern (`BufferPumpEndedTests.swift`) and an unstarted
  `EngineGraph()`; no audio device.
- `FormatConverterFoldTests`: build a 6-channel `AVAudioPCMBuffer` in code
  with layout MPEG_5_1_A, tone in Ls and Rs only. Convert to stereo at the
  same rate and at a different rate. Assert L and R RMS both above 0.05.
  Repeat with the tone in L and R only and assert the fold is louder than
  the surround case. Repeat with no channel layout on the source (the
  step 3 decision).
- `AVFoundationDecoderTests`: open `surround-lsrs-48000.m4a`, assert
  `sourceFormat.channelCount == 6`, then run a `BufferPump` at stereo 48000
  through at least one read and assert `scheduledBufferCount > 0` with no
  error. Before slice 1 this case fails with `decoderFailure`.
- `DecoderFactoryTests`: `decoder.selected` is emitted (assert through the
  `AppLogger` test seam the module already uses, or skip the assertion and
  rely on the line being read in review; do not add a log spy just for
  this).

Slice 2:

- Analyze the surround-only ALAC and the front-only ALAC. Both integrated
  LUFS values are finite and above −70. The front-only value is higher.
- Analyze a stereo fixture before and after the change: identical result.

Slice 3:

- `TagReaderFallbackTests`: raw `.ac3` (first, to record fact 7) and raw
  `.eac3` read without throwing; `channels == 6`, `duration > 0`, title is
  the filename stem.
- `DecoderFactoryTests`: `.eac3` and `.thd` route to `FFmpegDecoder` and
  report six channels. The chosen `.m4a` fallback fixture routes to
  `FFmpegDecoder`; a plain ALAC `.m4a` still routes to `AVFoundationDecoder`.
- A scan test in `Modules/Library` with the raw `.eac3` in a fixture folder
  asserts one imported track with `channelCount == 6`.

Slice 4:

- A view-model or snapshot test that a track with `channelCount == 6` shows
  "5.1", `2` shows "Stereo", `nil` shows no row.
- `make pseudolocale` passes. `Scripts/audit-help-text.py` passes.

All slices: `make format`, `make lint`, the module suite (`make
test-audio-engine`, `make test-metadata`, `make test-library`, `make
test-ui` as touched), `make build`, `make test-coverage`, then
`/slice-review` and the PR.

## Acceptance criteria

Slice 1:

- A 5.1 ALAC at the device's own rate plays, with sound in both channels,
  where it stopped with an error before.
- A 5.1 file at another rate plays with the surrounds audible, where they
  were silent before.
- `FormatConverterFoldTests` passes with L and R above 0.05 RMS for the
  surround-only source.
- `pump.read.failed` no longer appears in the log for such a file, and
  `decoder.selected` appears once per load.

Slice 2:

- The surround-only ALAC measures a finite LUFS; before the change it
  measured silence or a value from the wrong channels.

Slice 3:

- A folder containing `surround-lsrs-48000.eac3` scans to one track that
  plays; before, the scan logged `scan.tag_read_failed` and imported nothing.
- The `.m4a` fallback fixture plays; before, it failed with
  `accessDenied`.

Slice 4:

- Get Info on a 5.1 track shows "5.1" with hover text; on a stereo track
  shows "Stereo"; `make pseudolocale` is green and the data dictionary
  lists the two new readers.

## Gotchas

- **`AVAudioConverter.downmix` is off by default.** Without it a channel
  count change is a remap, not a mix: extra channels are dropped. This is
  the whole cause of the muting. It is one line.
- **Channel order is per container.** MP4 ALAC and AAC give C L R Ls Rs LFE;
  E-AC-3 gives L C R Ls Rs LFE; FLAC and WAV give L R C LFE Ls Rs. Never
  index channels 0 and 1 as left and right for more than two channels.
- **The read failure is catchable on macOS 26.** #515's original text said
  it terminates the app; it does not here. Keep the fix shape, drop the
  claim. If a reporter on an older macOS sends a crash log with
  `NSInvalidArgumentException` from `AVAudioFile`, that is the same bug on
  an older AVFoundation, and slice 1 fixes it the same way.
- **The ipod muxer refuses E-AC-3.** `ffmpeg ... -c:a eac3 out.m4a` fails
  with "Could not find tag for codec eac3"; pass `-f mp4`.
- **`AVAudioFile` refuses TrueHD** (`kAudioFileUnsupportedFileTypeError`,
  `1954115647`). Any TrueHD test goes through FFmpeg.
- **A converter relabelled on one side only fails.** If the default-layout
  step is needed, apply it to the decoder's format so the pump's buffers
  carry it too.
- **Do not widen the fixture size.** A one-second 6-channel WAV is 576 kB.
  Quarter-second, and prefer FLAC or ALAC over WAV.
- **The test runner survives this bug.** Because the read fails with an
  error rather than an exception, an end-to-end test that hits the old path
  fails normally. No need to test only the decision.
- **`ReplayGainAnalyzer` swallows mid-stream read errors as EOF**
  (`ReplayGainAnalyzer.swift:104`). A fold failure there must not look like
  a short file; log it.
- **Loudness numbers differ between folds.** Apple's fold and swresample's
  fold give different levels for the same source, and Dolby's own is
  different again. Slice 2 measures Apple's because that is what plays.
  Do not compare against theoretical coefficients in a test.

## Handoff

Run each slice as its own session on its own branch from an up-to-date
`main`. Paste the prompt below, then the whole of this file.

Slice 1 prompt:

> Implement slice 1 of docs/design-spec/ADR-091-multichannel-playback.md on a
> branch named fix/515-multichannel-fold. Start with the fixtures and the
> FormatConverterFoldTests so the muting is proven before it is fixed. Follow
> the root CLAUDE.md gates and the Modules/AudioEngine/CLAUDE.md testing
> rule. Do not touch slices 2 to 4. Run /slice-review before the PR. The PR
> closes #515 and references #513.

Slice 2 prompt:

> Implement slice 2 of docs/design-spec/ADR-091-multichannel-playback.md on a
> branch named fix/multichannel-replaygain, from a main that contains slice
> 1. Do not implement BS.1770 multichannel weighting; the spec says why.
> Run /slice-review before the PR.

Slice 3 prompt:

> Implement slice 3 of docs/design-spec/ADR-091-multichannel-playback.md on a
> branch named feat/raw-dolby-files. Begin by confirming fact 7 with a raw
> .ac3 fixture and record the result in the PR body. Keep TrueHD out of the
> scanner; the spec says why. Run /slice-review before the PR.

Slice 4 prompt:

> Implement slice 4 of docs/design-spec/ADR-091-multichannel-playback.md on a
> branch named feat/channel-count-info. Every string is localized, every
> new key gets make pseudolocale, and the data dictionary notes gain the two
> readers. Run /slice-review before the PR.

When slice 1 lands, comment on #513 that surround mixes now play folded to
stereo, that the reporter's "surround channels muted" case is fixed, and
that Bòcan does not render Atmos objects. If his "crash" was something
else, the new `decoder.selected` line in the log console is what to ask for.
