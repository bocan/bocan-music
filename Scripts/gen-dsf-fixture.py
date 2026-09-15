#!/usr/bin/env python3
"""Write a small DSD64 stereo DSF test fixture carrying a 440 Hz tone (#518).

FFmpeg has a DSF demuxer and no muxer, so the AudioEngine fixture for the
DSF decoder route cannot come from ffmpeg like the others. The format is
simple enough to write directly (Sony "DSF File Format Specification" 1.0.4):

    "DSD " chunk   28 bytes: total file size and a metadata pointer (0, none)
    "fmt " chunk   52 bytes: version, DSD raw, stereo, 2 822 400 Hz, 1 bit
                   per sample packed LSB first, sample count, block size 4096
    "data" chunk   1-bit samples, interleaved per channel in 4096-byte blocks

The bitstream is a first-order sigma-delta modulation of the tone: enough
for a decoder to lock on and produce the tone at the right level (a 0.5
amplitude sine decodes to about -9 dBFS RMS through FFmpeg's DSD decoder),
not a listening-grade modulator. Output is deterministic for a given
platform's libm, and the fixture is checked in, so it is generated once.

Usage: gen-dsf-fixture.py OUT.dsf [seconds] [amplitude]
       defaults: 0.25 s, 0.5 (about 180 kB)
"""

import math
import struct
import sys

DSD64_RATE = 2_822_400
CHANNELS = 2
BLOCK_BYTES = 4096  # per channel per block, fixed by the specification
TONE_HZ = 440.0
IDLE_BYTE = 0x69  # 01101001: a DC-free pattern for the block padding


def modulate(seconds: float, amplitude: float) -> tuple[bytes, int]:
    """First-order sigma-delta of the tone, packed LSB first, block padded.

    Returns the packed bytes for one channel and the unpadded sample count.
    """
    count = int(DSD64_RATE * seconds)
    packed = bytearray()
    integrator = 0.0
    byte = 0
    for i in range(count):
        x = amplitude * math.sin(2 * math.pi * TONE_HZ * i / DSD64_RATE)
        y = 1.0 if integrator >= 0 else -1.0
        integrator += x - y
        if y > 0:
            byte |= 1 << (i % 8)
        if i % 8 == 7:
            packed.append(byte)
            byte = 0
    if count % 8:
        packed.append(byte)
    packed.extend(bytes([IDLE_BYTE]) * ((-len(packed)) % BLOCK_BYTES))
    return bytes(packed), count


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 0.25
    amplitude = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5

    channel, samples = modulate(seconds, amplitude)
    data = bytearray()
    for offset in range(0, len(channel), BLOCK_BYTES):
        block = channel[offset:offset + BLOCK_BYTES]
        data += block  # left
        data += block  # right: the same tone on both sides

    fmt_chunk = struct.pack(
        "<4sQIIIIIIQII",
        b"fmt ", 52,
        1,           # format version
        0,           # format id: DSD raw
        2,           # channel type: stereo
        CHANNELS,
        DSD64_RATE,
        1,           # bits per sample: 1 means LSB first
        samples,     # sample count per channel
        BLOCK_BYTES,
        0,           # reserved
    )
    data_chunk = struct.pack("<4sQ", b"data", 12 + len(data)) + data
    total = 28 + len(fmt_chunk) + len(data_chunk)
    dsd_chunk = struct.pack("<4sQQQ", b"DSD ", 28, total, 0)

    with open(path, "wb") as out:
        out.write(dsd_chunk)
        out.write(fmt_chunk)
        out.write(data_chunk)
    print(f"wrote {path}: {total} bytes, {samples} samples per channel, {seconds} s")


if __name__ == "__main__":
    main()
