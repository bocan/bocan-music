# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `AudioEngine` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

The realtime audio path. The public seam other modules consume is the `Transport` protocol (`Transport.swift`); the concrete implementation is the `AudioEngine` actor.

- `AudioEngine.swift` (plus the `AudioEngine+*.swift` extensions: AntiPop, CUE, DSP, Gapless, GaplessAPI, Reconnect, ReplayGain, StreamDetails, Tap) is the actor that owns the `AVAudioEngine` graph. `Graph/` holds the `AVAudioPlayerNode`-backed `EngineGraph` and `BufferPump`. A crossfade is mixed inside the pump (`Graph/BufferPump+Overlap.swift`, ADR-095), never by ramping the node volume.
- `Decoder/` is the format split: `FormatSniffer` + `DecoderFactory` choose between `AVFoundationDecoder` (local files AVFoundation can open) and `FFmpegDecoder` (everything else, and all HTTP/HTTPS streams).
- `DSP/` is the effects chain (EQ, bass boost, crossfeed, stereo width) plus `DSP/Presets/`. `ReplayGain/` measures loudness and resolves the gain to play at; the gain itself is applied per track inside the buffer pump (`PumpSource.gain`), never on a node in the graph (#573). `Tap/` feeds the visualizer/FFT. `Streaming/` holds `SubsonicStreamCache` and the HTTP transport.
- `Transcode/` is the offline encode path for Phone Sync (ADR-088): `TranscodePreset` (the quality-rung vocabulary) and the `AudioTranscoder` actor, which demuxes, decodes, resamples, encodes (libmp3lame / libopus), muxes, and hashes through the same CFFmpeg module, one file at a time at utility priority.

## Things easy to get wrong

- **FFmpeg is the project's own LGPL source build, linked by path, never Homebrew's and never through pkg-config** (ADR-096). `Package.swift` declares the C system-module as a bare `.systemLibrary(name: "CFFmpeg")` and passes `-I<prefix>/include` and `-L<prefix>/lib`, where the prefix is `build/ffmpeg-lgpl` at the repo root (`FFMPEG_PREFIX` overrides it for command-line builds). `make test-audio-engine` is a plain `swift test` and sets no environment. If a local `swift test`/`swift build` inside `Modules/AudioEngine` fails with "libavcodec/avcodec.h file not found", the build is missing: run `make ffmpeg-lgpl` (a git worktree needs its own). Never add `/opt/homebrew/include` or `/opt/homebrew/lib` here. `RequiredCodecsTests` is the contract with that build: it asserts the licence string and every decoder, demuxer, protocol, encoder and muxer the app relies on, so a change to the configure line in `Scripts/build-ffmpeg-lgpl.sh`, or a new format, has a case there.
- **`AVAudioFile` snapshots a file's length at open time**, so it truncates live streams. `DecoderFactory.make(for:)` routes HTTP/HTTPS to `FFmpegDecoder` for exactly this reason; any new playback path must honour the same split.
- **`SubsonicStreamCache` waits for the full download before signalling readiness**, by design. The old "play while downloading" path silently truncated tracks because of the `AVAudioFile` snapshot. Do not reintroduce mid-download signalling without also swapping to a streaming-aware decoder.
- **A render block is Objective-C, never a Swift closure.** The crossfeed and stereo-width units run on the real-time thread on every cycle, switched on or not. Their render blocks and state live in the `AudioEngineKernels` target (`Sources/AudioEngineKernels`), in classes that override `internalRenderBlock` in Objective-C; the Swift classes in `DSP/` subclass them and must not override it. A Swift render block allocates on the audio thread (once per cycle in every build, once per sample in a debug build), and that made the debug build crackle whenever the UI was busy. `RenderKernelTests` counts allocations with the `RenderProbe` test target and must read zero; a new unit gets a case there.
- **FFmpeg C calls need RAII discipline.** Allocation can succeed and a later call still fail; free on every throw path (the `FFContext` cleanup contract and the `buildSWR` free-on-throw `defer` pattern). All FFmpeg free functions are NULL-safe.

## Testing

Run `make test-audio-engine` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/AudioEngine`, or `make test-coverage`), run `make test-audio-engine` last so the full module suite is the final gate before the commit.
