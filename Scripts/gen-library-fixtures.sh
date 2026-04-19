#!/usr/bin/env bash
# gen-library-fixtures.sh
#
# Generates a sample-library of tagged audio fixtures for LibraryTests.
# Requires ffmpeg (brew install ffmpeg) and id3v2 (brew install id3v2).
#
# Usage:
#   ./Scripts/gen-library-fixtures.sh
#
# Re-running is idempotent: existing files are skipped.
# CI caches the output directory; run only on cache miss.

set -euo pipefail

FIXTURES_DIR="$(dirname "$0")/../Modules/Library/Tests/LibraryTests/Fixtures/sample-library"
mkdir -p "$FIXTURES_DIR"

cd "$FIXTURES_DIR"

# Helper — skip if file already exists and is non-empty.
make_fixture() {
    local file="$1"; shift
    if [[ -s "$file" ]]; then
        echo "  skip  $file"
        return 0
    fi
    echo "  gen   $file"
    "$@"
}

# ─── Single Artist album ─────────────────────────────────────────────────────

mkdir -p "Artist A/Album One"

make_fixture "Artist A/Album One/01 - First Track.mp3" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k \
    -metadata title="First Track" \
    -metadata artist="Artist A" \
    -metadata album="Album One" \
    -metadata track="1" \
    -metadata year="2020" \
    -metadata genre="Rock" \
    "Artist A/Album One/01 - First Track.mp3" -y -loglevel error

make_fixture "Artist A/Album One/02 - Second Track.mp3" \
    ffmpeg -f lavfi -i "sine=frequency=550:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k \
    -metadata title="Second Track" \
    -metadata artist="Artist A" \
    -metadata album="Album One" \
    -metadata track="2" \
    -metadata year="2020" \
    -metadata genre="Rock" \
    "Artist A/Album One/02 - Second Track.mp3" -y -loglevel error

make_fixture "Artist A/Album One/03 - Third Track.flac" \
    ffmpeg -f lavfi -i "sine=frequency=660:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -sample_fmt s32 -c:a flac \
    -metadata title="Third Track" \
    -metadata artist="Artist A" \
    -metadata album="Album One" \
    -metadata tracknumber="3" \
    -metadata date="2020" \
    -metadata genre="Rock" \
    "Artist A/Album One/03 - Third Track.flac" -y -loglevel error

# ─── M4A (AAC + ALAC) ────────────────────────────────────────────────────────

mkdir -p "Artist B/EP One"

make_fixture "Artist B/EP One/01 - AAC Track.m4a" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -c:a aac -b:a 128k \
    -metadata title="AAC Track" \
    -metadata artist="Artist B" \
    -metadata album="EP One" \
    -metadata track="1/2" \
    "Artist B/EP One/01 - AAC Track.m4a" -y -loglevel error

make_fixture "Artist B/EP One/02 - ALAC Track.m4a" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -c:a alac \
    -metadata title="ALAC Track" \
    -metadata artist="Artist B" \
    -metadata album="EP One" \
    -metadata track="2/2" \
    "Artist B/EP One/02 - ALAC Track.m4a" -y -loglevel error

# ─── OGG Vorbis + Opus ───────────────────────────────────────────────────────

mkdir -p "Artist C/Single"

make_fixture "Artist C/Single/01 - Vorbis Track.ogg" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
    -ac 2 -ar 48000 -c:a vorbis -q:a 5 -strict experimental \
    -metadata title="Vorbis Track" \
    -metadata artist="Artist C" \
    -metadata album="Single" \
    -metadata tracknumber="1" \
    "Artist C/Single/01 - Vorbis Track.ogg" -y -loglevel error

make_fixture "Artist C/Single/02 - Opus Track.opus" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
    -ac 2 -ar 48000 -c:a libopus -b:a 128k -strict experimental \
    -metadata title="Opus Track" \
    -metadata artist="Artist C" \
    -metadata album="Single" \
    -metadata tracknumber="2" \
    "Artist C/Single/02 - Opus Track.opus" -y -loglevel error

# ─── WAV ─────────────────────────────────────────────────────────────────────

mkdir -p "Artist D/Lossless"

make_fixture "Artist D/Lossless/01 - WAV Track.wav" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -sample_fmt s16 \
    -metadata title="WAV Track" \
    -metadata artist="Artist D" \
    -metadata album="Lossless" \
    "Artist D/Lossless/01 - WAV Track.wav" -y -loglevel error

# ─── Multi-disc album ─────────────────────────────────────────────────────────

mkdir -p "Artist E/Double Album/Disc 1"
mkdir -p "Artist E/Double Album/Disc 2"

make_fixture "Artist E/Double Album/Disc 1/01 - Disc 1 Track 1.flac" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -sample_fmt s32 -c:a flac \
    -metadata title="Disc 1 Track 1" \
    -metadata artist="Artist E" \
    -metadata album="Double Album" \
    -metadata tracknumber="1" \
    -metadata discnumber="1/2" \
    "Artist E/Double Album/Disc 1/01 - Disc 1 Track 1.flac" -y -loglevel error

make_fixture "Artist E/Double Album/Disc 2/01 - Disc 2 Track 1.flac" \
    ffmpeg -f lavfi -i "sine=frequency=550:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -sample_fmt s32 -c:a flac \
    -metadata title="Disc 2 Track 1" \
    -metadata artist="Artist E" \
    -metadata album="Double Album" \
    -metadata tracknumber="1" \
    -metadata discnumber="2/2" \
    "Artist E/Double Album/Disc 2/01 - Disc 2 Track 1.flac" -y -loglevel error

# ─── Compilation (Various Artists) ───────────────────────────────────────────

mkdir -p "Various Artists/Compilation"

make_fixture "Various Artists/Compilation/01 - Artist F Track.mp3" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k \
    -metadata title="Artist F Track" \
    -metadata artist="Artist F" \
    -metadata album_artist="Various Artists" \
    -metadata album="Compilation" \
    -metadata track="1" \
    -metadata compilation="1" \
    "Various Artists/Compilation/01 - Artist F Track.mp3" -y -loglevel error

make_fixture "Various Artists/Compilation/02 - Artist G Track.mp3" \
    ffmpeg -f lavfi -i "sine=frequency=550:sample_rate=44100:duration=2" \
    -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k \
    -metadata title="Artist G Track" \
    -metadata artist="Artist G" \
    -metadata album_artist="Various Artists" \
    -metadata album="Compilation" \
    -metadata track="2" \
    -metadata compilation="1" \
    "Various Artists/Compilation/02 - Artist G Track.mp3" -y -loglevel error

# ─── Edge cases ──────────────────────────────────────────────────────────────

mkdir -p "EdgeCases"

# Missing tags (title/artist/album all absent)
make_fixture "EdgeCases/no-tags.mp3" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k \
    -map_metadata -1 \
    "EdgeCases/no-tags.mp3" -y -loglevel error

# Unicode filename
make_fixture "EdgeCases/こんにちは世界.flac" \
    ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -sample_fmt s32 -c:a flac \
    -metadata title="こんにちは世界" \
    -metadata artist="Unicode Artist" \
    "EdgeCases/こんにちは世界.flac" -y -loglevel error

# Corrupt/truncated file — write a tiny invalid file
if [[ ! -s "EdgeCases/corrupt.mp3" ]]; then
    echo "  gen   EdgeCases/corrupt.mp3"
    printf '\xFF\xFB\x90\x00NOTREALAUDIO' > "EdgeCases/corrupt.mp3"
fi

# Sidecar cover art — generate a real 10×10 JPEG via ffmpeg
if [[ ! -s "Artist A/Album One/cover.jpg" ]]; then
    echo "  gen   Artist A/Album One/cover.jpg"
    ffmpeg -f lavfi -i "color=c=blue:size=10x10:duration=0.04:rate=25" \
        -vframes 1 -f image2 "Artist A/Album One/cover.jpg" -y -loglevel error
fi

# Sidecar LRC lyrics
if [[ ! -s "Artist A/Album One/01 - First Track.lrc" ]]; then
    echo "  gen   Artist A/Album One/01 - First Track.lrc"
    cat > "Artist A/Album One/01 - First Track.lrc" << 'EOF'
[ti:First Track]
[ar:Artist A]
[al:Album One]
[00:00.00]First line of lyrics
[00:02.50]Second line of lyrics
[00:05.00]Third line of lyrics
EOF
fi

# Hidden file (should be skipped by FileWalker)
if [[ ! -e "Artist A/Album One/.hidden.mp3" ]]; then
    echo "  gen   Artist A/Album One/.hidden.mp3 (hidden, skipped by walker)"
    touch "Artist A/Album One/.hidden.mp3"
fi

# Non-audio file (should be skipped by FileWalker)
if [[ ! -e "Artist A/Album One/artwork.psd" ]]; then
    echo "  gen   Artist A/Album One/artwork.psd (non-audio, skipped)"
    touch "Artist A/Album One/artwork.psd"
fi

echo ""
echo "Done. Sample library written to:"
echo "  $FIXTURES_DIR"
echo ""
find "$FIXTURES_DIR" -type f | sort
