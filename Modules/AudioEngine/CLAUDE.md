# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `AudioEngine` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

The realtime audio path. The public seam other modules consume is the `Transport` protocol (`Transport.swift`); the concrete implementation is the `AudioEngine` actor.

- `AudioEngine.swift` (plus the `AudioEngine+*.swift` extensions: AntiPop, Crossfade, DSP, Gapless, Tap) is the actor that owns the `AVAudioEngine` graph. `Graph/` holds the `AVAudioPlayerNode`-backed `EngineGraph` and `BufferPump`.
- `Decoder/` is the format split: `FormatSniffer` + `DecoderFactory` choose between `AVFoundationDecoder` (local files AVFoundation can open) and `FFmpegDecoder` (everything else, and all HTTP/HTTPS streams).
- `DSP/` is the effects chain (EQ, bass boost, crossfeed, stereo width) plus `DSP/Presets/`. `ReplayGain/` applies loudness normalisation. `Tap/` feeds the visualizer/FFT. `Streaming/` holds `SubsonicStreamCache` and the HTTP transport.

## Things easy to get wrong

- **FFmpeg is linked from Homebrew via pkg-config, not vendored.** `make test-audio-engine` provides the environment; a raw `swift test`/`swift build` inside `Modules/AudioEngine` may fail to locate FFmpeg without `PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg/lib/pkgconfig`. The C system-module is declared in `Package.swift` with `pkgConfig`/`.brew(["ffmpeg"])`.
- **`AVAudioFile` snapshots a file's length at open time**, so it truncates live streams. `DecoderFactory.make(for:)` routes HTTP/HTTPS to `FFmpegDecoder` for exactly this reason; any new playback path must honour the same split.
- **`SubsonicStreamCache` waits for the full download before signalling readiness**, by design. The old "play while downloading" path silently truncated tracks because of the `AVAudioFile` snapshot. Do not reintroduce mid-download signalling without also swapping to a streaming-aware decoder.
- **FFmpeg C calls need RAII discipline.** Allocation can succeed and a later call still fail; free on every throw path (the `FFContext` cleanup contract and the `buildSWR` free-on-throw `defer` pattern). All FFmpeg free functions are NULL-safe.

## Testing

Run `make test-audio-engine` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/AudioEngine` with the FFmpeg `PKG_CONFIG_PATH` set, or `make test-coverage`), run `make test-audio-engine` last so the full module suite is the final gate before the commit.
