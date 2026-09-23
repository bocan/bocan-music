#!/usr/bin/env bash
# encode-mp4.sh: turn the demo recording into an MP4 that social sites accept.
#
# Usage: Scripts/demo/encode-mp4.sh build/demo/demo.mov build/demo/demo.mp4 [width] [fps]
#
# The recording is H.264 already, but at Retina size, a nominal 120 fps with a
# variable frame rate, and with no audio stream at all. Facebook and friends
# want a constant 30 fps or less, an AAC track, and the index at the front, so
# this re-encodes at a fixed rate, adds a silent stereo track the length of the
# video, and moves the index for streaming.
set -euo pipefail

in="${1:?input .mov}"
out="${2:?output .mp4}"
width="${3:-1920}"
fps="${4:-30}"

command -v ffmpeg >/dev/null || { echo "ffmpeg is missing: brew install ffmpeg" >&2; exit 1; }
mkdir -p "$(dirname "$out")"

ffmpeg -loglevel error -y -i "$in" \
    -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000" -shortest \
    -r "$fps" -vf "scale=${width}:-2:flags=lanczos" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 20 -preset slow \
    -c:a aac -b:a 64k -movflags +faststart \
    "$out"

size=$(du -h "$out" | cut -f1)
echo "wrote $out ($size)"
