# Phase 1 — Audio Engine & Single-File Playback

> Prerequisites: Phase 0 complete. `Observability` module importable. App launches.
>
> Read `phases/_standards.md` first.

## Goal

Play one audio file at a time with transport controls (play/pause/stop/seek). Support both AVFoundation-native formats and non-native formats via an FFmpeg-backed decoder. No queue, no UI beyond debug hooks — **one file in, PCM out, speakers on**.

## Non-goals

- Queue, next/previous, gapless — Phase 5.
- Library, metadata, DB — Phases 2/3.
- EQ, ReplayGain — Phase 9.
- Real UI — just enough to poke it for manual testing (a dev-only debug view is fine).

## Outcome shape

```
Modules/AudioEngine/
├── Package.swift
├── Sources/AudioEngine/
│   ├── AudioEngine.swift            # Facade, public
│   ├── PlaybackState.swift          # enum + AsyncStream publisher
│   ├── Transport.swift              # Public transport protocol
│   ├── Decoder/
│   │   ├── Decoder.swift            # protocol
│   │   ├── DecoderFactory.swift
│   │   ├── FormatSniffer.swift      # magic-byte detection
│   │   ├── AVFoundationDecoder.swift
│   │   └── FFmpegDecoder.swift
│   ├── Graph/
│   │   ├── EngineGraph.swift        # owns AVAudioEngine + nodes
│   │   ├── BufferPump.swift         # pulls from Decoder, schedules on PlayerNode
│   │   └── DeviceRouter.swift       # output device enumeration/selection
│   ├── Errors.swift                 # AudioEngineError
│   └── Internal/
│       ├── AudioTime.swift          # time conversion helpers
│       ├── FormatConverter.swift    # sample-rate/bit-depth normalisation
│       └── RingBuffer.swift         # lock-free PCM ring (if needed for FFmpeg path)
└── Tests/AudioEngineTests/
    ├── DecoderFactoryTests.swift
    ├── AVFoundationDecoderTests.swift
    ├── FFmpegDecoderTests.swift
    ├── EngineTransportTests.swift
    ├── GapFreeSeekTests.swift
    └── Fixtures/
        ├── sine-1s-44100-16-stereo.wav
        ├── sine-1s-44100-24-stereo.flac
        ├── sine-1s-48000-stereo.ogg
        ├── sine-1s-48000-stereo.opus
        ├── sine-1s-dsd64-stereo.dsf
        ├── sample.mp3
        ├── sample.m4a (AAC)
        ├── sample.m4a (ALAC)
        └── corrupt.mp3
```

## Implementation plan

1. **Create `Modules/AudioEngine` Swift Package**, depend on `Observability`.
2. **Vendor FFmpeg** (decision point — pick one, record it in `DEVELOPMENT.md`):
   - Option A: [SwiftFFmpeg](https://github.com/sunlubo/SwiftFFmpeg) via SPM. Pros: easy. Cons: maintenance status uncertain — verify when you start.
   - Option B: Build a minimal in-tree `CFFmpeg` system-module target linking Homebrew's FFmpeg statically. Requires a small `module.modulemap`. **Recommended** for long-term control.
   - LGPL-only FFmpeg build is sufficient; do **not** enable `--enable-gpl` or `--enable-nonfree` (simplifies redistribution).
3. **Define `Decoder` protocol** (see Contracts).
4. **Implement `AVFoundationDecoder`** wrapping `AVAudioFile`. Handle 8/16/24/32-bit integer, 32/64-bit float source formats. Produce `AVAudioPCMBuffer` in a canonical output format (see `FormatConverter`).
5. **Implement `FFmpegDecoder`** using libavformat for demux, libavcodec for decode, libswresample to resample to the canonical format. Target formats: OGG/Vorbis, Opus, DSF, DFF, APE, WavPack, WMA Lossless.
6. **`FormatSniffer`** — read first 16 bytes, match magic:
   - `"RIFF"` → WAV → AV
   - `"fLaC"` → FLAC → AV
   - `"ID3 " / 0xFF 0xFB` → MP3 → AV
   - `"ftyp"` at offset 4 → M4A (AAC/ALAC) → AV
   - `"OggS"` → OGG/Opus → FFmpeg (further sniff the codec by reading the first page)
   - `"DSD "` → DSF → FFmpeg
   - `"FRM8"` → DFF → FFmpeg
   - `"MAC "` → APE → FFmpeg
   - `"wvpk"` → WavPack → FFmpeg
   - Fallback: let FFmpeg try; if it fails, throw `.unsupportedFormat`.
7. **`DecoderFactory`**: `static func make(for url: URL) throws -> any Decoder`. Never uses file extension alone.
8. **`EngineGraph`** (actor): owns `AVAudioEngine`, one `AVAudioPlayerNode`, a `AVAudioMixerNode` in front of the output (for later EQ insert). Canonical internal format: `Float32, interleaved = false, sampleRate = output device native, channels = 2` — but accept any decoder format and interpose `FormatConverter` if needed.
9. **`BufferPump`**: reads `AVAudioPCMBuffer` from the decoder in a background `Task`, schedules them onto the player node. Keeps a small in-flight window (e.g. 4 × 200ms buffers) and throttles via buffer-completion callbacks. Respects cancellation.
10. **`Transport` + `AudioEngine` facade**:
    ```swift
    public protocol Transport: Sendable {
        func load(_ url: URL) async throws
        func play() async throws
        func pause() async
        func stop() async
        func seek(to time: TimeInterval) async throws
        var currentTime: TimeInterval { get async }
        var duration: TimeInterval { get async }
        var state: AsyncStream<PlaybackState> { get }
    }
    ```
11. **`PlaybackState`** enum: `.idle`, `.loading`, `.ready`, `.playing`, `.paused`, `.stopped`, `.ended`, `.failed(AudioEngineError)`.
12. **`DeviceRouter`**: enumerate output devices (CoreAudio `AudioObjectGetPropertyData` — wrap in a Sendable struct). Expose `current` + `set(_:)`. If the current output device disappears mid-playback, fall back to the new default and log `.notice`.
13. **System event handling**:
    - Default-output-device change → reconfigure engine.
    - Audio route interruption (macOS doesn't use `AVAudioSession` the way iOS does — listen for `AudioHardwarePropertyDefaultOutputDevice` notifications instead).
    - Sleep/wake → pause on sleep; resume on wake **only if** we were playing (configurable later, default no).
14. **Dev-only debug view** in the App target (behind `#if DEBUG`): a file picker + play/pause/stop/seek slider + current-time label. Not test-covered, purely for manual smoke-testing.
15. **Clipping protection**: add an `AVAudioUnitEQ` in bypass mode now so the chain is ready for Phase 9. No gain changes yet.
16. **Logging**: every public op logs start/end with duration; every error logs at `.error`.

## Definitions & contracts

### `Decoder.swift`

```swift
public protocol Decoder: Sendable, AnyObject {
    /// Source file. Must be a local URL with security-scoped access already granted by the caller.
    init(url: URL) throws

    /// The native format produced by this decoder (before any conversion).
    var sourceFormat: AVAudioFormat { get }

    /// Total duration in seconds. May be nil for streams that don't know their length.
    var duration: TimeInterval { get }

    /// Current read head in seconds.
    var position: TimeInterval { get async }

    /// Read up to `buffer.frameCapacity` frames into `buffer`.
    /// Returns the number of frames written. 0 means EOF.
    /// Throws on decode errors. Callers must treat EOF and errors distinctly.
    func read(into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount

    /// Seek to an approximate time. Precision is codec-dependent.
    func seek(to time: TimeInterval) async throws

    /// Release underlying resources. After this, the decoder is unusable.
    func close() async
}
```

### `AudioEngineError`

```swift
public enum AudioEngineError: Error, Sendable, CustomStringConvertible {
    case fileNotFound(URL)
    case accessDenied(URL, underlying: Error?)
    case unsupportedFormat(magic: Data, url: URL)
    case decoderFailure(codec: String, underlying: Error)
    case formatConversionFailure(from: AVAudioFormat, to: AVAudioFormat)
    case engineStartFailed(underlying: Error)
    case outputDeviceUnavailable
    case seekOutOfRange(requested: TimeInterval, duration: TimeInterval)
    case cancelled
    // `description` implementation must include all associated values.
}
```

### Canonical internal format

- `Float32`, non-interleaved, 2 channels.
- Sample rate tracks the current output device's native rate (queried on engine start and on device change).
- Mono input is duplicated to stereo by the converter. 5.1/7.1 is down-mixed with standard ITU coefficients for v1 (surround output is out of scope).

## Context7 lookups

- `use context7 AVAudioEngine attachNode connect macOS`
- `use context7 AVAudioPlayerNode scheduleBuffer completionCallbackType`
- `use context7 AVAudioFile common format processing format`
- `use context7 AVAudioConverter sample rate`
- `use context7 FFmpeg libavcodec libswresample decode to PCM`
- `use context7 CoreAudio AudioObjectGetPropertyData default output device`
- `use context7 Swift 6 strict concurrency AVFoundation`

## Dependencies

- **SwiftFFmpeg** (or in-tree `CFFmpeg` module target) via SPM.
- FFmpeg itself: pinned Homebrew formula version, documented in `DEVELOPMENT.md`. CI must install the same version (`brew install ffmpeg@<pinned>` in CI).
- Nothing else.

## Test plan

Fixtures live in `Modules/AudioEngine/Tests/AudioEngineTests/Fixtures/`. Generate deterministic sine-wave fixtures via a committed script `Scripts/gen-audio-fixtures.sh` (FFmpeg one-liners) — the script runs in CI on cache miss; the resulting files are cached.

- **FormatSniffer**: feed 32-byte heads of each supported format; verify correct `Codec` returned. Include negative cases (random bytes → nil).
- **DecoderFactory**: returns `AVFoundationDecoder` for WAV/FLAC/MP3/M4A; returns `FFmpegDecoder` for OGG/Opus/DSF.
- **AVFoundationDecoder**: opens each native fixture, reads all frames, asserts total frames ≈ `duration × sampleRate`. Seek to 0.5s, read, assert position.
- **FFmpegDecoder**: same contract against non-native fixtures.
- **Sine-wave sanity**: decode 1s of 440 Hz sine, FFT, verify peak bin at 440 Hz ± 1 bin and amplitude within 3 dB.
- **Engine transport**: load a 2s fixture, `play()` → state transitions `idle → loading → ready → playing → ended`; `pause()` → `.paused` and `currentTime` stops advancing; `seek(to: 1.0)` → `currentTime ≈ 1.0`.
- **Error paths**: missing file → `.fileNotFound`; corrupt MP3 → `.decoderFailure`; unsupported magic → `.unsupportedFormat`.
- **Cancellation**: cancel the enclosing `Task` during playback; decoder closes; no leaks (use `weak self` assertions).
- **Property-based**: random sequence of `play/pause/seek/stop` operations never produces `.failed`. Position after `pause` is monotonic on resume.
- **Performance smoke**: decode a 10-minute FLAC in less than realtime × 0.1 (fast enough for pre-decode in Phase 5).
- **Device change**: mock `DeviceRouter` emits a change event; engine reconfigures without dropping state.

## Acceptance criteria

- [ ] Plays MP3, AAC, ALAC, FLAC, WAV via `AVFoundationDecoder`.
- [ ] Plays OGG/Vorbis, Opus, DSF via `FFmpegDecoder`.
- [ ] `play / pause / stop / seek` all work from the debug view.
- [ ] `AudioEngineError.description` is human-readable for every case.
- [ ] `PlaybackState` stream reports every transition with no duplicates.
- [ ] 80%+ line coverage on `AudioEngine`.
- [ ] `make lint && make test-coverage` green.
- [ ] Manual test: play a 10-minute FLAC, seek forward/back, pause/resume — no audible glitches, idle CPU < 5%.
- [ ] No data races under Thread Sanitizer (`-enableThreadSanitizer YES` in the test scheme).

## Gotchas

- **Sample-rate mismatch** between source and output device is the #1 bug source. Always route through `AVAudioConverter`; don't assume `AVAudioEngine` handles it silently.
- **FFmpeg timestamps** are in a stream-specific time base. Convert using `av_rescale_q`; never assume milliseconds.
- **DSD** is 1-bit @ 2.8224 MHz (DSD64). You must decimate to PCM (e.g. 176.4 kHz / 24-bit) via libswresample with a proper low-pass. Don't pretend you can ship raw DSD to CoreAudio — CoreAudio doesn't speak it on Mac without a bespoke HAL.
- **Opus** is always 48 kHz internally. Expose the real 48 kHz, let the converter resample if the output device is 44.1.
- **Seek in VBR MP3** is approximate. Document the precision in code comments; tests must not demand sample-accuracy there.
- **`AVAudioPlayerNode` time** (`playerTime(forNodeTime:)`) returns nil when stopped. Keep a monotonic wall-clock fallback while paused.
- **Hardened Runtime** will refuse to load an un-signed FFmpeg dylib. Prefer static linking; if dynamic, add `com.apple.security.cs.disable-library-validation` entitlement **only in Debug**, with a note to revisit before release.
- **CoreAudio device change notifications** arrive on a HAL thread. Hop to the engine's actor before mutating state.
- **AVFoundation's FLAC decoder** supports up to 24-bit / 384 kHz. Unusual high-res FLAC might still fall back to FFmpeg; sniffer should test by attempting `AVAudioFile` init and falling back on failure.
- **Memory**: `AVAudioPCMBuffer` is not cheap. Reuse buffers via a small pool in `BufferPump` (pre-allocate 4–8 buffers, round-robin).
- **App Sandbox**: the file URL must come from a security-scoped bookmark (we don't have the bookmark machinery yet — that's Phase 3). For Phase 1, assume the caller has just opened the file via `NSOpenPanel`, which grants ephemeral access.
- **Swift 6 + AVFoundation**: many AVFoundation types aren't `Sendable`. Contain them inside an `actor` and expose only `Sendable` DTOs across the boundary.

## Handoff

Phase 2 (Persistence) doesn't depend on this directly, but Phase 5 (Queue) will expect:

- `AudioEngine.load(_:)` can be called while another file is playing and cleanly replaces it.
- `AudioEngine` exposes the `AVAudioEngine` **indirectly** through an insertion point for later EQ (Phase 9) and taps (Phase 12). Do not expose the engine publicly; expose a protocol `AudioGraphInsertionPoint` that later phases conform filters to.
- Pre-decoding a next track is feasible: `Decoder` can be constructed and `read` can run without any engine involvement. (Phase 5 will exploit this.)
- `BufferPump` pulls all decode work onto a background actor so multiple pumps can coexist (future gapless).
