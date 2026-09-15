#!/usr/bin/env python3
"""Set the legacy channelcount field of an MP4 file's Dolby sample entry (#529).

An AudioSampleEntry ('ac-3' or 'ec-3' box) in an MP4 carries a 16-bit
channelcount at byte 24 from the box start. ETSI TS 102 366 sets it to 2 for
compatibility and puts the real layout in the dac3 / dec3 box, which is what
Dolby-encoded files in the wild carry. FFmpeg's muxer writes the real count
there instead, so a fixture that reproduces the wild files needs this patch.

Usage: set-mp4-channelcount.py FILE.m4a COUNT
"""

import struct
import sys

CHANNELCOUNT_OFFSET = 24  # header 8 + reserved 6 + data_reference_index 2 + reserved 8


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, count = sys.argv[1], int(sys.argv[2])
    data = bytearray(open(path, "rb").read())
    fourcc = data.find(b"ec-3")
    if fourcc < 0:
        fourcc = data.find(b"ac-3")
    if fourcc < 4:
        sys.exit(f"{path}: no ec-3 or ac-3 sample entry")
    box = fourcc - 4
    at = box + CHANNELCOUNT_OFFSET
    before = struct.unpack(">H", data[at:at + 2])[0]
    data[at:at + 2] = struct.pack(">H", count)
    with open(path, "wb") as out:
        out.write(data)
    print(f"{path}: channelcount {before} -> {count}")


if __name__ == "__main__":
    main()
