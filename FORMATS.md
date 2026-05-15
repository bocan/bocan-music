# Supported Formats

Bòcan detects formats by **magic bytes** — never file extensions — so renamed
files are decoded correctly without guessing.

Decoding uses two back-ends:

- **AVFoundation** — Apple's built-in audio stack. Zero extra dependencies.
- **FFmpeg (LGPL)** — bundled FFmpeg libraries, LGPL build only (no GPL codecs).

---

## Lossless PCM

| Format | Extensions | Engine |
|---|---|---|
| WAV / RIFF PCM | `.wav` | AVFoundation |
| AIFF / AIFF-C | `.aiff` `.aif` | FFmpeg |
| AU / SND | `.au` `.snd` | FFmpeg |
| Wave64 | `.w64` | FFmpeg — removes the 4 GB WAV size limit |
| RF64 / Broadcast Wave | `.wav` `.bwf` | FFmpeg — detected by magic bytes, not extension |

## Lossless Compressed

| Format | Extensions | Engine |
|---|---|---|
| FLAC | `.flac` | AVFoundation (FFmpeg fallback for unusual streams) |
| ALAC | `.m4a` `.alac` `.mp4` | AVFoundation |
| Monkey's Audio | `.ape` | FFmpeg |
| WavPack | `.wv` | FFmpeg — lossless, hybrid-lossy, and DSD modes |

## Lossy

| Format | Extensions | Engine |
|---|---|---|
| MP3 (MPEG Layer 3) | `.mp3` | AVFoundation |
| MP2 (MPEG Layer 2) | `.mp2` | FFmpeg |
| MP1 (MPEG Layer 1) | `.mp1` | FFmpeg |
| AAC | `.aac` `.m4a` `.m4b` `.mp4` | AVFoundation |
| OGG Vorbis / Speex / Ogg FLAC | `.ogg` | FFmpeg — content type detected automatically |
| Opus | `.opus` `.ogg` | FFmpeg |
| WMA | `.wma` | FFmpeg (ASF container) |
| Musepack | `.mpc` | FFmpeg |
| AC-3 / Dolby Digital | `.ac3` | FFmpeg |
| DTS | `.dts` | FFmpeg |
| TTA (True Audio) | `.tta` | FFmpeg |

## DSD

DSD is decoded to PCM via DoP (DSD over PCM) for output to standard DACs.

| Format | Extensions | Engine |
|---|---|---|
| DSF | `.dsf` | FFmpeg — Sony DSD Stream File |
| DFF / DSDIFF | `.dff` | FFmpeg — Philips DSDIFF |

## Containers

| Format | Extensions | Engine |
|---|---|---|
| Matroska / MKV / WebM | `.mkv` `.mka` `.webm` | FFmpeg — audio tracks extracted automatically |
| MP4 / M4A | `.mp4` `.m4a` `.m4b` | AVFoundation |

---

## Output

All formats are decoded internally to **32-bit float PCM**. Output to hardware
supports up to **32-bit / 384 kHz**. DSD is output via DoP.

## What isn't supported

- **TAK** — patent-encumbered; no LGPL-safe decoder available
- **SACD ISO** — raw disc images; individual DSF/DFF tracks play fine
- **RealAudio** (`.ra`, `.rm`) — no LGPL-safe decoder
- **WMA Lossless / WMA Pro** — may fall back to FFmpeg probe; results vary
- **Encrypted files** — Apple DRM (FairPlay) and WMA DRM files will not play
