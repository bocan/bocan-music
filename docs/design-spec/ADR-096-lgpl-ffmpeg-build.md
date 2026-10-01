# ADR-096: An LGPL FFmpeg Build, and a Gate That Proves It

> Depends on: ADR-002 (the engine and the FFmpeg rule, line 66), ADR-032
> (distribution, the licence rule at line 274), ADR-033 (the release
> pipeline, which the maintainer owns), ADR-088 (the MP3 and Opus encoders
> Phone Sync uses).
> Binding docs: `_standards.md`; the root `CLAUDE.md`; `DEVELOPMENT.md`
> ("FFmpeg", "fpcalc", "Releasing"); `docs/GOTCHAS.md`.
> Found on 2026-10-01 during the docs-against-code audit. Status: proposed.
> Not started. Nothing in this ADR is legal advice.

Everything under "Facts the plan rests on" was read from the repository on
`main` at `76f13c0b`, from the installed release app (2.19.0), or from the
FFmpeg 9.0.2 source's own `LICENSE.md`, on 2026-10-01.

## Goal

Ship an FFmpeg that is licensed under the LGPL, as the project has required
since its first spec, and make it impossible to ship anything else without a
red build.

Three things have to be true when this ADR is done:

1. Every FFmpeg library inside `Bocan.app` (both the copy in
   `Contents/Frameworks` and the copy beside `fpcalc` in
   `Contents/Resources`) reports an LGPL licence, and no GPL-only library
   (`libx264`, `libx265`) is in the bundle.
2. The release workflow fails, before signing, when point 1 is false.
3. `NOTICES.md`, the website and the developer docs say what the binary is,
   and give the source and build recipe the LGPL asks for.

## Non-goals

- **Changing what the app can play.** The same formats decode after this
  change as before it. A format that stops playing is a defect in this work.
- **A redesign of the release pipeline.** The pipeline is the maintainer's
  (ADR-033). This ADR adds a build step, changes where two existing steps get
  their inputs, and adds one gate. Slice 4 is delivered as a PR for the
  maintainer to review and run; no release is cut by the implementer.
- **Vendoring FFmpeg source or binaries in git.** The source is fetched at a
  pinned version and checksum, built, and cached.
- **Static linking.** FFmpeg stays in dynamic libraries (see Gotchas, "LGPL
  and replaceability").
- **TagLib.** It is LGPL-2.1 or MPL-1.1 already and is not touched.
- **Deciding what to do about the releases already published.** That is
  recorded as an open decision for the maintainer (Decisions, D5), with the
  options; this ADR does not choose.
- **Removing the second copy of the FFmpeg dylibs.** The app carries one copy
  in `Frameworks` and one in `Resources` for `fpcalc`. Sharing one copy is a
  worthwhile follow-up and is out of scope here.

## Facts the plan rests on

1. **The rule is as old as the project.** ADR-002 line 66 (2026-04-18):
   "LGPL-only FFmpeg build is sufficient; do **not** enable `--enable-gpl` or
   `--enable-nonfree`". ADR-032 line 274: "Keep FFmpeg configured LGPL-only;
   explicitly pass `--disable-gpl --disable-nonfree` when building."
2. **The rule was never implemented.** No commit in the history builds
   FFmpeg. `git log -S"disable-gpl"` and `git log -S"./configure"` over
   `Scripts`, `.github` and `Makefile` find only the spec text. The project
   chose "Option B: system module + Homebrew dynamic linking"
   (`DEVELOPMENT.md`, "FFmpeg"), and Homebrew's formula is
   `license "GPL-3.0-or-later"`, configured with `--enable-gpl
   --enable-version3 --enable-libx264 --enable-libx265 --enable-openssl`.
3. **Every release ships that build.** `Scripts/build-fpcalc.sh` copies
   `fpcalc` and its Homebrew dylibs into `Resources/`;
   `Scripts/embed-deps.sh` (since `e8903094`, 2026-05-06) copies every
   Homebrew dylib the main binary references into `Contents/Frameworks`. The
   first tag, `v0.2.0` (2026-05-01), already bundled the `fpcalc` set.
4. **The shipped app, checked.** In `/Applications/Bocan.app` 2.19.0,
   `strings` on `libavcodec.63.dylib`, `libavformat.63.dylib`,
   `libavutil.61.dylib` and `libswresample.7.dylib` each gives "GPL version 3
   or later". `Contents/Frameworks` holds `libx264.165.dylib`,
   `libx265.217.dylib`, `libvpx`, `libdav1d`, `libSvtAv1Enc`, `liblzma`,
   `libssl`, `libcrypto`, `libmp3lame`, `libopus`, `libmpg123`. The dylibs in
   `Frameworks` total 34 MB.
5. **The notices contradict themselves.** `NOTICES.md` line 12 says the
   libraries are "built without any GPL or non-free components" and line 20
   names `homebrew-core/Formula/f/ffmpeg.rb` as the build recipe. The website
   (`formats.njk`, `_data/credits.json`) and three wiki pages repeat "LGPL".
6. **Nothing checks.** No script, test or workflow step reads the licence of
   a built or bundled library. `Scripts/check-ffmpeg-major.sh` checks the
   major version only.
7. **What the app uses from FFmpeg.** `Modules/AudioEngine` is the only
   importer (`Sources/CFFmpeg/shim.h`): `libavformat`, `libavcodec`,
   `libswresample`, `libavutil`. It uses demuxers and audio decoders for
   every non-AVFoundation format in `FormatSniffer` (Ogg Vorbis, Speex, Opus,
   MP1/MP2, APE, WavPack, DSF/DFF, AU, Wave64, RF64, Matroska, AC-3, E-AC-3,
   DTS, TrueHD, WMA, Musepack, TTA, and FLAC/AIFF/MP4 as fallbacks); the
   network protocols `http,https,tls,tcp,crypto`
   (`FFmpegDecoder+Options.swift`, the `protocol_whitelist`); ICY metadata;
   the HLS demuxer (`TLSTrustExport.swift` exists because of its nested
   opens); and two encoders with their muxers, `libmp3lame` (MP3) and
   `libopus` (Opus in Ogg), for Phone Sync (`Transcode/TranscodePreset.swift`).
8. **None of that is GPL.** FFmpeg 9.0.2's `LICENSE.md` lists the GPL parts:
   three x86 optimization files, some build and test tools, about thirty
   video filters in `libavfilter`, and the external libraries `libx264`,
   `libx265`, `libxvid` and others. Every decoder, demuxer, protocol and the resampler the app uses is
   in the LGPL part. `libmp3lame` is LGPL-2.0-or-later, `libopus` is
   BSD-3-Clause. The same file says of OpenSSL: "To the best of our
   knowledge, [it is] compatible with the LGPL."
9. **TLS depends on OpenSSL today.** FFmpeg's OpenSSL backend finds its
   trust roots through `SSL_CERT_FILE`, which `TLSTrustExport` sets to a PEM
   export of the macOS trust store, so verification works in the sandbox
   (#393).
10. **How the build finds FFmpeg.** `Modules/AudioEngine/Package.swift`
    declares `.systemLibrary(name: "CFFmpeg", pkgConfig: "libavformat
    libavcodec libswresample libavutil", providers: [.brew(["ffmpeg"])])`.
    Four manifests also pass `-I/opt/homebrew/include` and
    `-L/opt/homebrew/lib` as unsafe flags. CI exports
    `PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg/lib/pkgconfig:...`.
11. **`fpcalc` comes from Homebrew's `chromaprint`**, which depends on
    Homebrew's `ffmpeg`. Installing it installs the GPL build.
12. **Codec fixtures are thin.** `Tests/AudioEngineTests/Fixtures` has files
    for MP3, AAC, ALAC, FLAC, WAV, AIFF, WavPack, Ogg Vorbis, Opus, DSF,
    E-AC-3 and TrueHD. There is no fixture for APE, WMA, DTS, AC-3,
    Musepack, TTA, AU, Wave64, Matroska or MP2.

## Decisions for the maintainer

The plan below assumes the recommended answer to each. A different answer
changes only the slice named.

- **D1. Licence version.** Recommended: LGPL v2.1 or later, which is the
  default when neither `--enable-gpl` nor `--enable-version3` is passed.
  Nothing the app needs requires version 3. (Slice 2.)
- **D2. TLS backend.** Recommended: keep OpenSSL (`--enable-openssl`). It
  needs no code change, and `TLSTrustExport` keeps working. The alternative
  is Apple's Secure Transport (`--enable-securetransport`), which reads the
  system trust store itself and would let `TLSTrustExport` go, but it is a
  deprecated Apple API and a behaviour change in the streaming path that
  needs its own testing. (Slice 2.)
- **D3. Developer machines.** Recommended: Debug builds keep using Homebrew's
  FFmpeg by default. A Debug build is not distributed, and requiring a
  source build to run the app would slow every fresh clone. `make
  ffmpeg-lgpl` builds the LGPL set locally for anyone who wants to run
  against it. (Slice 2.)
- **D4. PR CI.** Recommended: the PR workflow builds and tests against the
  LGPL build, from a cache, so a decoder that the LGPL build lacks fails a
  test and not a user. The branch-push workflow stays on Homebrew to stay
  fast. (Slice 5.)
- **D5. The releases already published** (v0.2.0 to 2.19.0) contain GPLv3
  FFmpeg and a notice that says otherwise. Options, not chosen here: (a)
  leave them and correct the notice from the next release on; (b) add a
  correction to the release notes of each affected release and to the
  website; (c) withdraw the old DMGs once a clean release exists. The source
  of Bòcan itself has always been public under Apache 2.0, which can be
  combined with GPLv3 code. Take advice if it matters.

## Outcome shape

New:

- `.ffmpeg-source`: the pinned FFmpeg version, tarball URL and SHA-256.
- `.chromaprint-source`: the same for Chromaprint.
- `Scripts/build-ffmpeg-lgpl.sh`: fetch, verify, configure, build, install
  into a prefix.
- `Scripts/check-bundle-licence.sh`: the gate.
- `Scripts/tests/check-bundle-licence-test.sh`: hermetic tests of the gate.
- `Modules/AudioEngine/Tests/AudioEngineTests/RequiredCodecsTests.swift`:
  asserts the linked FFmpeg has every decoder, demuxer, protocol, encoder and
  muxer the app relies on.

Changed:

- `Scripts/build-fpcalc.sh`: build `fpcalc` from source against the LGPL
  prefix when one is given; today's Homebrew path stays for Debug.
- `Scripts/embed-deps.sh`: bundle dylibs from the LGPL prefix as well as
  from Homebrew paths.
- `Makefile`: `ffmpeg-lgpl`, `check-licence`; `doctor` reports which FFmpeg
  the build will link.
- `.github/workflows/release.yml`, `.github/workflows/pr.yml`: see slices 4
  and 5.
- `Brewfile`: add `lame`, `opus`, `openssl@3` and `cmake` explicitly (today
  the libraries arrive as dependencies of `ffmpeg`), and a way to skip
  `ffmpeg` and `chromaprint` in the jobs that must be clean.
- `NOTICES.md`, `DEVELOPMENT.md`, `CLAUDE.md`, `Modules/AudioEngine/CLAUDE.md`,
  `docs/GOTCHAS.md`, `website/src/_data/credits.json`,
  `website/src/formats.njk`, `CHANGELOG.md`, and a note at the top of
  ADR-002 and ADR-032.

## What carries over from previous specs

- ADR-002 and ADR-032 state the rule; this ADR implements it and does not
  change it.
- ADR-033's release flow is unchanged in shape: same jobs, same order, same
  secrets.
- The `.ffmpeg-major` pin and `Scripts/check-ffmpeg-major.sh` stay. The new
  `.ffmpeg-source` pin must agree with it; `make doctor` checks that the two
  name the same major.
- The codec routing in `DecoderFactory` and `FormatSniffer` is not touched.
- `TLSTrustExport` is not touched (D2).

## Behavioural definitions and contracts

### The FFmpeg configure line

`Scripts/build-ffmpeg-lgpl.sh` runs exactly this, with `$PREFIX` defaulting
to `build/ffmpeg-lgpl`:

```bash
./configure \
  --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug \
  --disable-nonfree \
  --disable-avdevice --disable-avfilter --disable-swscale \
  --disable-encoders --enable-encoder=libmp3lame --enable-encoder=libopus \
  --disable-muxers --enable-muxer=mp3 --enable-muxer=ogg --enable-muxer=opus \
  --disable-hwaccels --disable-videotoolbox \
  --enable-audiotoolbox \
  --enable-libmp3lame --enable-libopus \
  --enable-openssl \
  --enable-neon \
  --arch=arm64 --cc=clang \
  --install-name-dir="$PREFIX/lib"
```

Rules for whoever edits it:

- `--enable-gpl` and `--enable-version3` never appear. `--disable-gpl` is not
  a configure option; the LGPL is what you get by not asking for the GPL.
- Decoders, demuxers, parsers, protocols and bitstream filters are **not**
  cut down with `--disable-everything`. The app's promise is that an unknown
  file goes to FFmpeg; a hand-kept allow-list would break that promise one
  format at a time. Video decoders ride along unused; that costs a few
  megabytes and no licence.
- Any new `--enable-lib*` needs a line in the PR that names the library's
  licence, from `LICENSE.md` in the pinned source.

The script verifies the tarball's SHA-256 before it unpacks it and fails on a
mismatch. It is idempotent: if `$PREFIX/.built-from` holds the same pin and
the same configure line, it does nothing.

### The gate

`Scripts/check-bundle-licence.sh <path-to-.app>` exits 0 only when all of
these hold, and prints one line per failure otherwise:

1. For every file under the app matching `libav*.dylib` or `libsw*.dylib`,
   in any directory: its strings contain `LGPL version 2.1 or later` and do
   not contain `GPL version` without the leading `L`, nor
   `nonfree and unredistributable`.
2. For the same files: the embedded configure line (the string that begins
   `--prefix=`) does not contain `--enable-gpl`, `--enable-version3` or
   `--enable-nonfree`.
3. No file in the app is named `libx264*`, `libx265*`, `libxvid*`,
   `libvidstab*`, `librubberband*` or `libpostproc*`.
4. At least one `libavcodec*.dylib` was found. An app with no FFmpeg at all
   is a broken bundle, not a clean one.
5. Every Mach-O in the app that links a `libav*` library resolves it inside
   the bundle (`@rpath`, `@loader_path`, `@executable_path`), never an
   absolute path.

Like `check-ffmpeg-major.sh`, the script takes its inputs through
overridable environment so its tests run on Linux: `STRINGS_CMD`,
`OTOOL_CMD` and `FIND_CMD` default to the real tools.

### Which FFmpeg a build links

- Release job: the LGPL prefix, always. Homebrew's `ffmpeg` and
  `chromaprint` are **not installed** in that job, so there is nothing else
  to link by accident.
- PR job (D4): the LGPL prefix.
- Branch-push job and developer machines (D3): Homebrew, unless
  `FFMPEG_PREFIX` is set. `make doctor` prints which one it is and the
  licence that library reports.

### The required-codecs contract

`RequiredCodecsTests` asserts, through the linked library and with no
fixture files:

- `avcodec_find_decoder` returns non-nil for: Vorbis, Speex, Opus, MP1, MP2,
  MP3, FLAC, ALAC, AAC, APE, WavPack, DSD (the four `DSD_*` ids), PCM
  families used by AU, Wave64 and AIFF, AC-3, E-AC-3, DTS (`DTS`), TrueHD,
  MLP, WMA v1, WMA v2, WMA Pro, WMA Lossless, Musepack 7, Musepack 8, TTA.
- `av_find_input_format` returns non-nil for: `ogg`, `matroska`, `asf`,
  `ape`, `wv`, `dsf`, `iff`, `au`, `w64`, `wav`, `aiff`, `mov`, `mp3`,
  `flac`, `ac3`, `eac3`, `dts`, `truehd`, `mpc`, `mpc8`, `tta`, `hls`.
- `avio_find_protocol_name` (or the protocol enumeration) includes `http`,
  `https`, `tls`, `tcp`, `crypto`, `file`.
- `avcodec_find_encoder_by_name` returns non-nil for `libmp3lame` and
  `libopus`; `av_guess_format` returns non-nil for the two container names
  the transcoder asks for (`mp3` and `opus` at the time of writing; read
  `AudioTranscoder+Pipeline.swift` for the exact call).

The implementer takes the exact id list from `FormatSniffer`,
`DecoderFactory` and `TranscodePreset` at the time of writing; the list
above is the floor, not a replacement for reading them.

## Implementation plan

Each slice is one commit or one PR, leaves `main` green, and can be done by a
separate session. Slices 1 to 3 change nothing that ships.

### Slice 1: the gate, with tests, not yet wired

1. Write `Scripts/check-bundle-licence.sh` to the contract above.
2. Write `Scripts/tests/check-bundle-licence-test.sh` in the style of
   `check-ffmpeg-major-test.sh`: fake `strings` and `otool` output through
   the environment overrides. Cases: clean LGPL bundle passes; GPL licence
   string fails; `--enable-gpl` in the configure line fails; a `libx264`
   file fails; no `libavcodec` fails; an absolute `/opt/homebrew` load path
   fails; the `Resources` copy is checked as well as the `Frameworks` copy.
3. Add `make check-licence APP=path`.
4. Run it by hand against `/Applications/Bocan.app` and record the output in
   the PR: it must fail, and name the four FFmpeg libraries and the two
   GPL encoders. That failure is the proof that the gate sees today's
   defect.

### Slice 2: the LGPL build, and the test that it is complete

1. Add `.ffmpeg-source` with the newest FFmpeg release whose major matches
   `.ffmpeg-major`, its `https://ffmpeg.org/releases/` URL and SHA-256.
2. Write `Scripts/build-ffmpeg-lgpl.sh` (contract above). Add `make
   ffmpeg-lgpl`.
3. Add `RequiredCodecsTests`.
4. Run the AudioEngine suite twice and put both results in the PR: against
   Homebrew, and with
   `PKG_CONFIG_PATH=$PWD/build/ffmpeg-lgpl/lib/pkgconfig` against the LGPL
   build. Both must pass. See Gotchas, "The Homebrew `-L` flag", before
   trusting the second run.
5. Confirm with `otool -L` on the built test binary that it loaded the LGPL
   dylibs, and with `strings` that they say LGPL.
6. Extend `make doctor` to print the FFmpeg in use and its licence, and to
   fail when `.ffmpeg-source` and `.ffmpeg-major` disagree.

### Slice 3: `fpcalc` against the LGPL build

1. Add `.chromaprint-source` (version, URL, SHA-256).
2. Teach `Scripts/build-fpcalc.sh` a second mode: when `FFMPEG_PREFIX` is
   set, build Chromaprint from source with CMake (`-DBUILD_TOOLS=ON`,
   `-DFFMPEG_ROOT=$FFMPEG_PREFIX`, `-DBUILD_SHARED_LIBS=ON`) and bundle
   `fpcalc` with the dylibs from that prefix. With `FFMPEG_PREFIX` unset it
   behaves as today.
3. Run the fingerprint tests (`make test-acoustics`, `make test-library`)
   with the source-built `fpcalc` in `Resources/`. Compare one real track's
   fingerprint from the Homebrew `fpcalc` and the new one: they must be
   identical.
4. Run `Scripts/check-bundle-licence.sh` against a Debug app built with
   `FFMPEG_PREFIX` set: the `Resources` copy must pass.

### Slice 4: the release uses it (maintainer review required)

1. `Scripts/embed-deps.sh`: treat `$FFMPEG_PREFIX` like a Homebrew prefix in
   `is_homebrew_path`, so dylibs referenced from there are bundled and
   rewritten.
2. `release.yml`, build job: replace "Install Brewfile dependencies (FFmpeg
   at the pinned major)" with: install the Brewfile **without** `ffmpeg` and
   `chromaprint`; restore the LGPL prefix from a cache keyed on
   `.ffmpeg-source`, `.chromaprint-source` and the two scripts; build on a
   miss; set `FFMPEG_PREFIX` and `PKG_CONFIG_PATH` to it.
3. After "Bundle Homebrew dylibs into app" and before "Verify code
   signature", add the step `bash Scripts/check-bundle-licence.sh
   build/export/Bocan.app`. A failure stops the release before anything is
   notarized or published.
4. Deliver as a PR. The maintainer runs `make release-preview` and the
   release itself. The implementer does not cut a release, does not tag, and
   does not re-run a published version.
5. After the first release from this pipeline, the maintainer (or a session
   they start) runs the gate against the downloaded DMG's app and records
   the result in the PR or the issue.

### Slice 5: PR CI on the LGPL build (D4)

1. `pr.yml`: same cache and prefix as slice 4; drop Homebrew `ffmpeg` and
   `chromaprint` from that job; run `make doctor` so the licence line is in
   the log.
2. `branch.yml` is not changed.
3. Check the PR job's wall-clock time against the last ten runs. A warm
   cache must not add more than about a minute; a cold one is a one-off.

### Slice 6: say what is true

1. `NOTICES.md`: rewrite the FFmpeg section. It must name the version, state
   LGPL v2.1 or later, link the exact source tarball, quote the configure
   line, and point to `Scripts/build-ffmpeg-lgpl.sh` as the build recipe.
   Add LAME, Opus and OpenSSL with their licences. Remove the reference to
   the Homebrew formula.
2. `DEVELOPMENT.md`, "FFmpeg": replace the Option A/B/C table with what is
   now done (source build for release and PR, Homebrew for Debug), and
   document `make ffmpeg-lgpl`, `FFMPEG_PREFIX` and `make check-licence`.
3. `CLAUDE.md` and `Modules/AudioEngine/CLAUDE.md`: one entry each.
4. `docs/GOTCHAS.md`: a new entry in the usual form (Problem, Rule, Why,
   Canonical file). The Problem is this ADR's Facts 1 to 6 in three
   sentences.
5. A dated note at the top of ADR-002 and ADR-032: the rule was not
   implemented until ADR-096.
6. `website/src/_data/credits.json` and `formats.njk`: keep "LGPL", which is
   then true; add the source link.
7. `CHANGELOG.md`, under Unreleased, in the listener's words: the app is
   smaller, and its audio libraries are now built by the project under the
   LGPL.
8. Give the wiki session the three pages to recheck:
   `Architecture-Overview.md`, `Features-Formats.md`,
   `Features-Playback-and-Sound.md`.

## Context7 lookups

Do these at the start of the slice that needs them; do not rely on memory.

- **FFmpeg** (`/websites/ffmpeg_documentation`): the "External libraries"
  licence notes; the `configure` options for the pinned major (`./configure
  --help` in the unpacked source is the final authority, since options are
  added and removed between majors); whether `--enable-securetransport`
  still exists in that major, if D2 changes.
- **FFmpeg `LICENSE.md` in the pinned tarball**: read it, do not assume it
  matches 9.0.2. The gate's licence strings come from `libavutil`'s
  `avutil_license()`; confirm the exact wording the pinned version prints.
- **Chromaprint**: its CMake options for the pinned version (`BUILD_TOOLS`,
  `FFMPEG_ROOT`, `AUDIO_PROCESSOR_LIB`), and its own licence (LGPL-2.1 or
  later at the time of writing; the FFT backend choice can change it).
- **GitHub Actions `actions/cache`**: key and restore-key behaviour, for the
  cache in slices 4 and 5.

## Dependencies

- Build tools, from Homebrew: `cmake` (for Chromaprint) and `pkgconf`. The
  app is arm64 only, so FFmpeg needs no x86 assembler; if `configure` asks
  for one, that is a sign the `--arch` flag was dropped.
- Libraries, from Homebrew: `lame` (LGPL-2.0-or-later), `opus`
  (BSD-3-Clause), `openssl@3` (Apache-2.0).
- No new Swift package. No change to any `Package.swift` dependency list.

## Test plan

- `make test-scripts`: the gate's hermetic cases (slice 1).
- `RequiredCodecsTests` under both FFmpeg builds (slice 2). It must pass on
  Homebrew too, so that it is not a test of the build flag alone.
- The whole AudioEngine suite against the LGPL build, with the linked
  library confirmed by `otool -L` (slice 2).
- `make test-acoustics` and `make test-library` with the source-built
  `fpcalc`, and the fingerprint comparison (slice 3).
- The gate against: the installed 2.19.0 (must fail); a Debug app built with
  `FFMPEG_PREFIX` (must pass); the exported release app in CI (must pass).
- Manual, by the maintainer, on the first build from the new pipeline: play
  one file of each format that has no fixture (APE, WMA, DTS, AC-3,
  Musepack, TTA, AU, Wave64, Matroska, MP2); play an HTTPS internet radio
  station and an HLS station; sync one track to a phone with an MP3 preset
  and one with an Opus preset; identify one track.
- No test hits the network. The source download happens in the build
  script, not in a test.

## Acceptance criteria

- [ ] `Scripts/check-bundle-licence.sh` fails on the installed 2.19.0 app and
      names each offending file.
- [ ] The same script passes on an app built by the release workflow.
- [ ] The release workflow has the gate as a step before signing
      verification, and a deliberately GPL prefix makes that step fail
      (shown once, in the PR, with a throwaway prefix; not committed).
- [ ] No `libx264`, `libx265`, `libvpx`, `libdav1d` or `libSvtAv1Enc` file
      is in the release app.
- [ ] `RequiredCodecsTests` passes against the LGPL build.
- [ ] The fingerprint of a reference track is identical before and after.
- [ ] `NOTICES.md` names the source tarball, the configure line and the
      build script, and no longer names the Homebrew formula.
- [ ] `make doctor` prints the FFmpeg in use and its licence.
- [ ] `docs/GOTCHAS.md` has the entry, and ADR-002 and ADR-032 carry the
      note.
- [ ] D5 has an answer recorded in the issue, even if the answer is "leave
      them".

## Gotchas

- **The Homebrew `-L` flag.** Four manifests pass `-L/opt/homebrew/lib`.
  On a machine that has Homebrew's FFmpeg installed, that directory holds
  `libavcodec.dylib` too, and the linker may take it before the LGPL prefix
  that `pkg-config` supplied. A green test run then proves nothing. Always
  confirm with `otool -L` on the built product. In the release and PR jobs
  the protection is that Homebrew's `ffmpeg` is not installed at all.
- **Homebrew's `chromaprint` pulls in Homebrew's `ffmpeg`.** Any job that
  must be clean cannot `brew install chromaprint`, and `brew bundle` will do
  exactly that if the Brewfile still lists it unconditionally. The Brewfile
  needs a way to skip the two formulae in those jobs (an environment
  variable read in the Brewfile is the usual pattern).
- **`--disable-gpl` does not exist.** ADR-032 asks for it. Passing an
  unknown option makes `configure` fail or, in some versions, warn and
  continue. The LGPL comes from the absence of `--enable-gpl`.
- **The licence string can mislead in one direction.** A library configured
  with `--enable-version3` but not `--enable-gpl` reports "LGPL version 3 or
  later". That is still LGPL, but it is not D1. The gate accepts only the
  2.1 wording on purpose; if D1 changes, change the gate in the same commit.
- **Same major, different ABI details.** The source build and Homebrew's
  build of the same version are ABI-compatible for the public API, but a
  binary built against one and run against the other can still differ in
  which codecs exist. Do not mix: `fpcalc` and the app both come from the
  same prefix in a release.
- **LGPL and replaceability.** The LGPL lets a user replace the library.
  Dynamic linking is what makes that practical, which is why static linking
  is a non-goal. The hardened runtime's library validation means a user who
  swaps a dylib must re-sign the app themselves; that is possible and is the
  usual position for a notarized Mac app, but this ADR does not assess it
  legally.
- **`TLSTrustExport` assumes OpenSSL.** If D2 moves to Secure Transport,
  `SSL_CERT_FILE` does nothing and that file should go, in the same change,
  with the HLS nested-open case tested.
- **Build time and the cache key.** FFmpeg takes a few minutes to build on a
  runner. The cache key must include the script and both pin files, or an
  edit to the configure line will silently reuse the old build.
- **`hiutil`-style silent failure.** The defect this ADR fixes survived five
  months because a step could not fail. Do not write `|| true` after the
  build script, the gate, or the checksum check.
- **Do not fix this by editing the notice.** Changing `NOTICES.md` to say
  "GPL" would make the documents consistent and leave the project in breach
  of its own rule.

## Handoff

This ADR is written for sessions that have not seen the investigation. Run
them in order; each prompt is one session.

1. `Read docs/design-spec/ADR-096-lgpl-ffmpeg-build.md. Do slice 1 only, on a
   branch chore/096-licence-gate. Do not wire the gate into any workflow.
   Show me the gate's output against /Applications/Bocan.app.`
2. `Read ADR-096. Do slice 2 only, on a branch feat/096-lgpl-ffmpeg-build.
   Do the Context7 lookups first. Before you claim the suite passes against
   the LGPL build, prove with otool -L which library the test binary
   loaded.`
3. `Read ADR-096. Do slice 3 only, on a branch feat/096-fpcalc-from-source.
   Show me the fingerprint comparison.`
4. `Read ADR-096. Do slice 4 only, on a branch ci/096-release-lgpl. This
   changes my release pipeline: make the smallest change that meets the
   slice, explain each changed step, and do not run or tag a release.`
5. `Read ADR-096. Do slice 5 only, on a branch ci/096-pr-lgpl. Report the PR
   job time before and after.`
6. `Read ADR-096. Do slice 6 only, on a branch docs/096-notices. Read the
   LICENSE.md of the pinned FFmpeg source before you write NOTICES.md.`

What the next ADR can rely on once this is done: `FFMPEG_PREFIX` names the
FFmpeg a build uses; a release cannot ship a GPL FFmpeg; and
`RequiredCodecsTests` is the list of what FFmpeg must provide, so a future
change to the configure line has a test to answer to.
