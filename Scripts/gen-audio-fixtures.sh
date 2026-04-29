#!/usr/bin/env bash
# gen-audio-fixtures.sh
#
# Generates deterministic sine-wave test fixtures for AudioEngineTests.
# Requires ffmpeg (brew install ffmpeg) and sox (brew install sox).
#
# Usage:
#   ./Scripts/gen-audio-fixtures.sh
#
# Re-running is idempotent: existing files are left unchanged.
# CI caches the output directory; run only on cache miss.

set -euo pipefail

FIXTURES_DIR="$(dirname "$0")/../Modules/AudioEngine/Tests/AudioEngineTests/Fixtures"
mkdir -p "$FIXTURES_DIR"

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

# NOTE: DSF (DSD Stream File) cannot be synthesised by FFmpeg — FFmpeg has no DSD encoder.
# The DSF fixture must be obtained from a real DSD source or created by a DSD-capable tool.
# For CI purposes, the DSF decoder test is skipped if the fixture is absent.
# sine-1s-dsd64-stereo.dsf — NOT auto-generated.

# 1 second, 440 Hz sine, 44100 Hz, WavPack
make_fixture "sine-1s-44100-stereo.wv" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -c:a wavpack "sine-1s-44100-stereo.wv" -y -loglevel error

# ── Corrupt / edge-case fixtures ─────────────────────────────────────────────

# Corrupt MP3 — first 64 bytes of a valid MP3 then random garbage.
if [[ ! -s "corrupt.mp3" ]]; then
    echo "  gen   corrupt.mp3"
    # Write a truncated MP3 ID3 header followed by zeroed payload.
    printf '\xFF\xFB\x90\x00' > "corrupt.mp3"   # sync word for CBR 128k 44100 stereo
    dd if=/dev/urandom bs=64 count=1 >> "corrupt.mp3" 2>/dev/null
fi

echo "Done. Fixtures in $FIXTURES_DIR"
