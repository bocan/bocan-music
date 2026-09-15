#!/usr/bin/env bash
# gen-audio-fixtures.sh
#
# Generates deterministic sine-wave test fixtures for AudioEngineTests,
# MetadataTests and LibraryTests.
# Requires ffmpeg (brew install ffmpeg) and python3 (for the DSF fixture).
#
# Usage:
#   ./Scripts/gen-audio-fixtures.sh
#
# Re-running is idempotent: existing files are left unchanged.
# CI caches the output directory; run only on cache miss.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/../Modules"
FIXTURES_DIR="$MODULES_DIR/AudioEngine/Tests/AudioEngineTests/Fixtures"
METADATA_FIXTURES_DIR="$MODULES_DIR/Metadata/Tests/MetadataTests/Fixtures"
LIBRARY_FIXTURES_DIR="$MODULES_DIR/Library/Tests/LibraryTests/Fixtures"
mkdir -p "$FIXTURES_DIR" "$METADATA_FIXTURES_DIR" "$LIBRARY_FIXTURES_DIR"

cd "$FIXTURES_DIR"

# Helper — skip if file already exists and is non-empty.
make_fixture() {
    local file="$1"; shift
    if [[ -s "$file" ]]; then
        echo "  skip  $file (already exists)"
        return 0
    fi
    echo "  gen   $file"
    "$@"
}

# ── Native (AVFoundation) fixtures ───────────────────────────────────────────

# 1 second, 440 Hz sine wave, 44100 Hz, 16-bit stereo WAV
make_fixture "sine-1s-44100-16-stereo.wav" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -sample_fmt s16 "sine-1s-44100-16-stereo.wav" -y -loglevel error

# 1 second, 440 Hz sine, 44100 Hz, 24-bit stereo FLAC
make_fixture "sine-1s-44100-24-stereo.flac" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -sample_fmt s32 -c:a flac "sine-1s-44100-24-stereo.flac" -y -loglevel error

# 3 seconds, 440 Hz sine, 44100 Hz, CBR MP3 (128k)
make_fixture "sample.mp3" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=3" \
    -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k "sample.mp3" -y -loglevel error

# 3 seconds, 440 Hz sine, 44100 Hz, AAC in M4A
make_fixture "sample-aac.m4a" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=3" \
    -ac 2 -ar 44100 -c:a aac -b:a 128k "sample-aac.m4a" -y -loglevel error

# 3 seconds, 440 Hz sine, 44100 Hz, ALAC in M4A
make_fixture "sample-alac.m4a" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=3" \
    -ac 2 -ar 44100 -c:a alac "sample-alac.m4a" -y -loglevel error

# ── FFmpeg fixtures ───────────────────────────────────────────────────────────

# 1 second, 440 Hz sine, 48000 Hz, OGG/Vorbis
# Use -strict -2 since vorbis encoder is experimental in FFmpeg
make_fixture "sine-1s-48000-stereo.ogg" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1" \
    -ac 2 -ar 48000 -c:a vorbis -strict -2 -q:a 5 "sine-1s-48000-stereo.ogg" -y -loglevel error

# 1 second, 440 Hz sine, 48000 Hz, Opus in OGG
make_fixture "sine-1s-48000-stereo.opus" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1" \
    -ac 2 -ar 48000 -c:a libopus -b:a 128k "sine-1s-48000-stereo.opus" -y -loglevel error

# Quarter second, 440 Hz sine, DSD64 stereo DSF. FFmpeg has a DSF demuxer
# and no muxer, so this one comes from gen-dsf-fixture.py, which writes the
# container and a first-order sigma-delta bitstream directly (#518).
make_fixture "sine-250ms-dsd64-stereo.dsf" \
    python3 "$SCRIPT_DIR/gen-dsf-fixture.py" "sine-250ms-dsd64-stereo.dsf" 0.25 0.5

# 1 second, 440 Hz sine, 44100 Hz, WavPack
make_fixture "sine-1s-44100-stereo.wv" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -c:a wavpack "sine-1s-44100-stereo.wv" -y -loglevel error

# ── Multichannel fixtures (ADR-091) ──────────────────────────────────────────
#
# Quarter-second 5.1 files. The surround group carries a 440 Hz tone in the
# rear pair (Ls, Rs) only, with digital silence in L, R, C and LFE, so a stereo
# fold that drops the surrounds is audibly (and measurably) silent. Kept to
# 0.25 s so the ALAC stays well under 100 kB.
#
# lavfi aevalsrc channel order for c=5.1 is FL|FR|FC|LFE|BL|BR.

SURROUND_48000='aevalsrc=0|0|0|0|0.5*sin(440*2*PI*t)|0.5*sin(440*2*PI*t):c=5.1:s=48000:d=0.25'
SURROUND_44100='aevalsrc=0|0|0|0|0.5*sin(440*2*PI*t)|0.5*sin(440*2*PI*t):c=5.1:s=44100:d=0.25'

# 5.1 ALAC in MP4, 48 kHz, tone in Ls and Rs only. AVFoundation route.
make_fixture "surround-lsrs-48000.m4a" \
    ffmpeg -f lavfi -i "$SURROUND_48000" \
    -c:a alac "surround-lsrs-48000.m4a" -y -loglevel error

# 5.1 FLAC, 44.1 kHz, tone in Ls and Rs only. The rate differs from a 48 kHz
# device, so this one exercises the resampling converter path.
make_fixture "surround-lsrs-44100.flac" \
    ffmpeg -f lavfi -i "$SURROUND_44100" \
    -c:a flac "surround-lsrs-44100.flac" -y -loglevel error

# 5.1 raw E-AC-3 (Dolby Digital Plus), 48 kHz. FFmpeg route.
make_fixture "surround-lsrs-48000.eac3" \
    ffmpeg -f lavfi -i "$SURROUND_48000" \
    -c:a eac3 "surround-lsrs-48000.eac3" -y -loglevel error

# 5.1 raw TrueHD, 48 kHz. AVAudioFile refuses TrueHD; FFmpeg route only.
make_fixture "surround-lsrs-48000.thd" \
    ffmpeg -f lavfi -i "$SURROUND_48000" \
    -c:a truehd -strict -2 "surround-lsrs-48000.thd" -y -loglevel error

# 5.1 E-AC-3 inside MP4, 48 kHz. The default ipod muxer refuses eac3
# ("Could not find tag for codec eac3"), so -f mp4 is required.
make_fixture "surround-lsrs-eac3-48000.m4a" \
    ffmpeg -f lavfi -i "$SURROUND_48000" \
    -c:a eac3 -f mp4 "surround-lsrs-eac3-48000.m4a" -y -loglevel error

# One-second 5.1 twins for the loudness measurement (ADR-091 slice 2). The
# EBU R128 meter needs one complete 400 ms block, so a quarter-second file
# always measures exactly -70 LUFS. E-AC-3 in MP4 because AVAudioFile opens
# it and a second of it is about 60 kB, where a second of 5.1 ALAC is 320 kB.
# Same tone: surround pair only in one, front pair only in the other.

SURROUND_1S_48000='aevalsrc=0|0|0|0|0.5*sin(440*2*PI*t)|0.5*sin(440*2*PI*t):c=5.1:s=48000:d=1'
FRONT_1S_48000='aevalsrc=0.5*sin(440*2*PI*t)|0.5*sin(440*2*PI*t)|0|0|0|0:c=5.1:s=48000:d=1'

make_fixture "surround-lsrs-1s-eac3-48000.m4a" \
    ffmpeg -f lavfi -i "$SURROUND_1S_48000" \
    -c:a eac3 -f mp4 "surround-lsrs-1s-eac3-48000.m4a" -y -loglevel error

make_fixture "front-lr-1s-eac3-48000.m4a" \
    ffmpeg -f lavfi -i "$FRONT_1S_48000" \
    -c:a eac3 -f mp4 "front-lr-1s-eac3-48000.m4a" -y -loglevel error

# The same second of surround-only E-AC-3 with no container (#522). It takes
# the FFmpeg route where the MP4 twin takes AVFoundation, so the pair proves
# both routes fold and measure the same mix to the same level.
make_fixture "surround-lsrs-1s-48000.eac3" \
    ffmpeg -f lavfi -i "$SURROUND_1S_48000" \
    -c:a eac3 "surround-lsrs-1s-48000.eac3" -y -loglevel error

# MP3 inside an MP4 container (ADR-091 slice 3). Sniffs as .m4a, and
# AVAudioFile refuses it (as it does DTS and TrueHD in MP4), so it proves the
# .m4a route falls back to FFmpeg. Opus and FLAC in MP4, the ADR's first two
# candidates, both open in AudioToolbox on macOS 26 and so cannot serve.
make_fixture "mp3-in-mp4.m4a" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=0.25" \
    -ac 2 -c:a libmp3lame -f mp4 "mp3-in-mp4.m4a" -y -loglevel error

# Opus inside an MP4 container (#523). On macOS 26 AVAudioFile opens it,
# reports length 0, and fails on the first read, so it proves the
# open-time probe in AVFoundationDecoder hands such a file to FFmpeg.
make_fixture "opus-in-mp4.m4a" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=0.25" \
    -ac 2 -c:a libopus -b:a 64k -f mp4 "opus-in-mp4.m4a" -y -loglevel error

# ── Corrupt / edge-case fixtures ─────────────────────────────────────────────

# Corrupt MP3 — first 64 bytes of a valid MP3 then random garbage.
if [[ ! -s "corrupt.mp3" ]]; then
    echo "  gen   corrupt.mp3"
    # Write a truncated MP3 ID3 header followed by zeroed payload.
    printf '\xFF\xFB\x90\x00' > "corrupt.mp3"   # sync word for CBR 128k 44100 stereo
    dd if=/dev/urandom bs=64 count=1 >> "corrupt.mp3" 2>/dev/null
fi

# ── Metadata fixtures ────────────────────────────────────────────────────────

cd "$METADATA_FIXTURES_DIR"

# 1 second FLAC carrying a bare KEY Vorbis comment (Picard / Mixed In Key
# style; TagLib does not alias it to INITIALKEY). Issue #407.
make_fixture "sine-1s-key-am.flac" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -sample_fmt s16 -c:a flac -metadata KEY=Am "sine-1s-key-am.flac" -y -loglevel error

# Raw Dolby files with no container and no tags (ADR-091 slice 3). TagLib
# has no AC-3 or E-AC-3 file type, so TagReader takes their duration,
# sample rate and channel count from AVFoundation instead.
make_fixture "surround-lsrs-48000.ac3" \
    ffmpeg -f lavfi -i "$SURROUND_48000" \
    -c:a ac3 "surround-lsrs-48000.ac3" -y -loglevel error

make_fixture "surround-lsrs-48000.eac3" \
    ffmpeg -f lavfi -i "$SURROUND_48000" \
    -c:a eac3 "surround-lsrs-48000.eac3" -y -loglevel error

# ── Library fixtures ─────────────────────────────────────────────────────────

# A folder holding one raw E-AC-3 file, for the scan test that asserts it
# imports with its channel count (ADR-091 slice 3).
mkdir -p "$LIBRARY_FIXTURES_DIR/dolby-library"
cd "$LIBRARY_FIXTURES_DIR/dolby-library"

make_fixture "surround-lsrs-48000.eac3" \
    ffmpeg -f lavfi -i "$SURROUND_48000" \
    -c:a eac3 "surround-lsrs-48000.eac3" -y -loglevel error

echo "Done. Fixtures in $FIXTURES_DIR, $METADATA_FIXTURES_DIR and $LIBRARY_FIXTURES_DIR"
