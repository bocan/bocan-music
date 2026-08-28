#!/usr/bin/env bash
# gen-picard-fixtures.sh
#
# Generates a small Picard-tagged library for the scan-then-assert-rows tests
# (issue #420): MusicBrainz ids, sort names, release types, totals in both
# TRACKTOTAL and n/N form, 16 and 24 bit, embedded and sidecar art, and an
# album mixed from two release ids. Checked in; re-run only to regenerate.
# Requires ffmpeg (brew install ffmpeg).
set -euo pipefail
FIXTURES_DIR="$(dirname "$0")/../Modules/Library/Tests/LibraryTests/Fixtures/picard-library"
mkdir -p "$FIXTURES_DIR"
cd "$FIXTURES_DIR"

make_fixture() {
    local file="$1"; shift
    if [[ -s "$file" ]]; then echo "  skip  $file"; return 0; fi
    echo "  gen   $file"
    "$@"
}

# Stable, obviously fake MBIDs (valid UUID shape).
AR_KESTRELS="11111111-1111-4111-8111-111111111111"
AR_STORM="22222222-2222-4222-8222-222222222222"
AR_SOLO1="33333333-3333-4333-8333-333333333333"
AR_SOLO2="44444444-4444-4444-8444-444444444444"
AR_VARIOUS="89ad4ac3-39f7-470e-963a-56509c546377"
REL_A="aaaaaaa1-aaaa-4aaa-8aaa-aaaaaaaaaaa1"; RG_1="aaaaaaa1-0000-4000-8000-000000000001"
REL_B="bbbbbbb1-bbbb-4bbb-8bbb-bbbbbbbbbbb1"; RG_2="bbbbbbb1-0000-4000-8000-000000000002"
REL_C1="ccccccc1-cccc-4ccc-8ccc-ccccccccccc1"; REL_C2="ccccccc2-cccc-4ccc-8ccc-ccccccccccc2"; RG_3="ccccccc1-0000-4000-8000-000000000003"

# Artwork: a 600x600 PNG to embed and a 300x300 JPEG sidecar.
make_fixture "_art/front.png" bash -c 'mkdir -p _art && ffmpeg -f lavfi -i "color=c=0x336699:s=600x600:d=1" -frames:v 1 _art/front.png -y -loglevel error'
mkdir -p "A Quiet Storm/Harbour EP"
make_fixture "A Quiet Storm/Harbour EP/cover.jpg" ffmpeg -f lavfi -i "color=c=0x996633:s=300x300:d=1" -frames:v 1 "A Quiet Storm/Harbour EP/cover.jpg" -y -loglevel error

# 1. The Kestrels / Morning Light: FLAC 24/96, sort tags, embedded art, TRACKTOTAL form.
mkdir -p "The Kestrels/Morning Light"
for n in 1 2; do
  t="The Kestrels/Morning Light/0$n - Kestrel $n.flac"
  make_fixture "$t" ffmpeg -f lavfi -i "sine=frequency=$((400 + n * 40)):sample_rate=96000:duration=1" -i _art/front.png \
    -map 0:a -map 1:v -c:a flac -sample_fmt s32 -ar 96000 -ac 2 -c:v png -disposition:v attached_pic \
    -metadata TITLE="Kestrel $n" -metadata ARTIST="The Kestrels" -metadata ALBUM="Morning Light" \
    -metadata ALBUMARTIST="The Kestrels" -metadata ARTISTSORT="Kestrels, The" -metadata ALBUMARTISTSORT="Kestrels, The" \
    -metadata TRACKNUMBER="$n" -metadata TRACKTOTAL="2" -metadata DISCNUMBER="1" -metadata DISCTOTAL="1" \
    -metadata DATE="2021" -metadata GENRE="Folk" -metadata RELEASETYPE="album" -metadata COMPOSER="R. Kestrel" \
    -metadata BPM="120" -metadata ISRC="GBTST210000$n" -metadata REPLAYGAIN_TRACK_GAIN="-6.50 dB" -metadata REPLAYGAIN_TRACK_PEAK="0.9$n" \
    -metadata REPLAYGAIN_ALBUM_GAIN="-7.00 dB" -metadata REPLAYGAIN_ALBUM_PEAK="0.99" \
    -metadata MUSICBRAINZ_ARTISTID="$AR_KESTRELS" -metadata MUSICBRAINZ_ALBUMARTISTID="$AR_KESTRELS" \
    -metadata MUSICBRAINZ_ALBUMID="$REL_A" -metadata MUSICBRAINZ_RELEASEGROUPID="$RG_1" \
    -metadata MUSICBRAINZ_TRACKID="rec-a$n" -metadata MUSICBRAINZ_RELEASETRACKID="trk-a$n" \
    "$t" -y -loglevel error
done

# 2. A Quiet Storm / Harbour EP: MP3 + M4A, no sort tag (derivation), n/N numbering, sidecar art, ep type.
make_fixture "A Quiet Storm/Harbour EP/01 - Harbour.mp3" ffmpeg -f lavfi -i "sine=frequency=500:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k \
    -metadata title="Harbour" -metadata artist="A Quiet Storm" -metadata album="Harbour EP" -metadata album_artist="A Quiet Storm" \
    -metadata track="1/2" -metadata disc="1/1" -metadata date="2019" -metadata genre="Ambient" -metadata RELEASETYPE="ep" \
    -metadata MUSICBRAINZ_ARTISTID="$AR_STORM" -metadata MUSICBRAINZ_ALBUMARTISTID="$AR_STORM" \
    -metadata MUSICBRAINZ_ALBUMID="$REL_B" -metadata MUSICBRAINZ_RELEASEGROUPID="$RG_2" \
    "A Quiet Storm/Harbour EP/01 - Harbour.mp3" -y -loglevel error
make_fixture "A Quiet Storm/Harbour EP/02 - Lighthouse.m4a" ffmpeg -f lavfi -i "sine=frequency=520:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -c:a aac -b:a 128k \
    -metadata title="Lighthouse" -metadata artist="A Quiet Storm" -metadata album="Harbour EP" -metadata album_artist="A Quiet Storm" \
    -metadata track="2/2" -metadata disc="1/1" -metadata date="2019" -metadata genre="Ambient" \
    "A Quiet Storm/Harbour EP/02 - Lighthouse.m4a" -y -loglevel error
# ffmpeg cannot write freeform iTunes atoms TagLib reads, so the M4A's MusicBrainz
# ids and RELEASETYPE were added once with Bòcan's own TagWriter (see
# Modules/Metadata/Tests/MetadataTests/PicardFixtureFinisherTests.swift, which
# only runs when BOCAN_FINISH_PICARD_FIXTURE=1) and the result committed.

# 3. Various Artists / Mixed Pressing: two discs, two track artists, two release ids in one release group, FLAC 16 + Ogg.
mkdir -p "Various Artists/Mixed Pressing"
make_fixture "Various Artists/Mixed Pressing/1-01 - Solo One Song.flac" ffmpeg -f lavfi -i "sine=frequency=600:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -sample_fmt s16 -c:a flac \
    -metadata TITLE="Solo One Song" -metadata ARTIST="Solo One" -metadata ALBUM="Mixed Pressing" -metadata ALBUMARTIST="Various Artists" \
    -metadata COMPILATION="1" -metadata TRACKNUMBER="1" -metadata TRACKTOTAL="1" -metadata DISCNUMBER="1" -metadata DISCTOTAL="2" \
    -metadata DATE="2005" -metadata RELEASETYPE="album" \
    -metadata MUSICBRAINZ_ARTISTID="$AR_SOLO1" -metadata MUSICBRAINZ_ALBUMARTISTID="$AR_VARIOUS" \
    -metadata MUSICBRAINZ_ALBUMID="$REL_C1" -metadata MUSICBRAINZ_RELEASEGROUPID="$RG_3" \
    "Various Artists/Mixed Pressing/1-01 - Solo One Song.flac" -y -loglevel error
# Homebrew ffmpeg may lack libvorbis; the built-in vorbis encoder is fine for a 1 s sine.
make_fixture "Various Artists/Mixed Pressing/2-01 - Solo Two Song.ogg" ffmpeg -f lavfi -i "sine=frequency=620:sample_rate=44100:duration=1" \
    -ac 2 -ar 44100 -c:a vorbis -strict -2 -b:a 96k \
    -metadata TITLE="Solo Two Song" -metadata ARTIST="Solo Two" -metadata ALBUM="Mixed Pressing" -metadata ALBUMARTIST="Various Artists" \
    -metadata COMPILATION="1" -metadata TRACKNUMBER="1" -metadata TRACKTOTAL="1" -metadata DISCNUMBER="2" -metadata DISCTOTAL="2" \
    -metadata DATE="2005" -metadata RELEASETYPE="album" \
    -metadata MUSICBRAINZ_ARTISTID="$AR_SOLO2" -metadata MUSICBRAINZ_ALBUMARTISTID="$AR_VARIOUS" \
    -metadata MUSICBRAINZ_ALBUMID="$REL_C2" -metadata MUSICBRAINZ_RELEASEGROUPID="$RG_3" \
    "Various Artists/Mixed Pressing/2-01 - Solo Two Song.ogg" -y -loglevel error

rm -rf _art
echo "picard-library ready in $FIXTURES_DIR"
