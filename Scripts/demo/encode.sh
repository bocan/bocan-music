#!/usr/bin/env bash
# encode.sh: turn the demo recording into a README-sized GIF.
#
# Usage: Scripts/demo/encode.sh build/demo/demo.mov build/demo/demo.gif [width] [fps]
#
# Uses gifski when it is installed (better colour and far smaller files at
# the same quality) and falls back to ffmpeg's two-pass palette otherwise.
set -euo pipefail

in="${1:?input .mov}"
out="${2:?output .gif}"
width="${3:-1280}"
fps="${4:-15}"

command -v ffmpeg >/dev/null || { echo "ffmpeg is missing: brew install ffmpeg" >&2; exit 1; }
mkdir -p "$(dirname "$out")"

if command -v gifski >/dev/null; then
    frames="$(mktemp -d)"
    trap 'rm -rf "$frames"' EXIT
    ffmpeg -loglevel error -i "$in" -vf "fps=${fps},scale=${width}:-1:flags=lanczos" "$frames/%05d.png"
    # gifski shrinks to about 800x600 unless told the width outright.
    gifski --fps "$fps" --width "$width" --quality 85 -o "$out" "$frames"/*.png
else
    echo "gifski is not installed (brew install gifski); using ffmpeg's palette path" >&2
    filters="fps=${fps},scale=${width}:-1:flags=lanczos"
    ffmpeg -loglevel error -y -i "$in" -vf "${filters},palettegen=stats_mode=diff" "$out.palette.png"
    ffmpeg -loglevel error -y -i "$in" -i "$out.palette.png" \
        -lavfi "${filters} [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" "$out"
    rm -f "$out.palette.png"
fi

size=$(du -h "$out" | cut -f1)
echo "wrote $out ($size). GitHub READMEs stay quick under about 10 MB; lower the width or fps if it is over."
