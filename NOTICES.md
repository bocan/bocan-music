# Third-Party Notices

Bòcan incorporates the following open-source components. Full licence texts are
reproduced below as required by each project's terms.

---

## FFmpeg 9.0.2

<https://ffmpeg.org>

Licensed under the **GNU Lesser General Public Licence, version 2.1 or later**
(LGPL 2.1+).

Bòcan builds FFmpeg itself, from the unmodified source release named below,
and configures it with none of `--enable-gpl`, `--enable-version3` and
`--enable-nonfree`. FFmpeg's own `LICENSE.md` says that in this
configuration the LGPL v2.1 or later applies to FFmpeg, and each built
library reports "LGPL version 2.1 or later". The release build stops if a
bundled FFmpeg library reports anything else
(`Scripts/check-bundle-licence.sh`).

The app ships four FFmpeg libraries, as separate dynamic libraries:
`libavcodec`, `libavformat`, `libavutil` and `libswresample`. There is
one copy in `Contents/Frameworks` and one copy beside the `fpcalc` helper
in `Contents/Resources`.

The LGPL 2.1 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

### Source and build recipe

- Source: <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>
- SHA-256 of that file: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`
- Build recipe: `Scripts/build-ffmpeg-lgpl.sh` in the Bòcan source
  (<https://github.com/bocan/bocan-music>), run as `make ffmpeg-lgpl`. The
  version, the address and the checksum are pinned in `.ffmpeg-source`.

The script runs this configure line, then `make` and `make install`:

```bash
./configure \
  --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug \
  --disable-nonfree \
  --disable-autodetect \
  --enable-zlib --enable-bzlib \
  --disable-avdevice --disable-avfilter --disable-swscale \
  --disable-encoders --enable-encoder=libmp3lame --enable-encoder=libopus \
  --disable-muxers --enable-muxer=mp3 --enable-muxer=ogg --enable-muxer=opus \
  --disable-hwaccels --disable-videotoolbox \
  --enable-audiotoolbox \
  --enable-libmp3lame --enable-libopus \
  --enable-openssl \
  --enable-neon \
  --arch=arm64 --cc=clang \
  --install-name-dir="$PREFIX/lib" \
  --extra-cflags="-mmacosx-version-min=$DEPLOYMENT_TARGET -I$LAME_PREFIX/include" \
  --extra-ldflags="-mmacosx-version-min=$DEPLOYMENT_TARGET -L$LAME_PREFIX/lib"
```

`$PREFIX` is the directory the libraries are installed into
(`build/ffmpeg-lgpl` by default). `$DEPLOYMENT_TARGET` is the oldest
macOS the app runs on (15.0). `$LAME_PREFIX` is the Homebrew directory of
the LAME library.

### External libraries in this build

The configure line turns autodetection off, so the build links only the
libraries it names: LAME, Opus and OpenSSL (each has its own section below),
the zlib and bzip2 libraries that come with macOS, and Apple's AudioToolbox
framework.

### Independent JPEG Group

Three files in `libavcodec` (`jfdctfst.c`, `jfdctint_template.c` and
`jrevdct.c`) come from libjpeg. This software is based in part on the work
of the Independent JPEG Group.

---

## LAME 4.0

<https://lame.sourceforge.io>

The MP3 encoder (`libmp3lame`). FFmpeg uses it when Phone Sync converts a
track to MP3. Licensed under the **GNU Library General Public Licence,
version 2 or later** (LGPL 2.0+). It is shipped as a separate dynamic
library, unmodified, as built by Homebrew.

The LGPL 2.0 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html>

LAME source code is available at <https://lame.sourceforge.io>.

---

## mpg123 1.33.7

<https://www.mpg123.de>

`libmpg123` is shipped because Homebrew's build of LAME links it. Licensed
under the **GNU Lesser General Public Licence, version 2.1**. It is shipped
as a separate dynamic library, unmodified, as built by Homebrew.

The LGPL 2.1 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

mpg123 source code is available at <https://www.mpg123.de/download/>.

---

## Opus 1.6.1

<https://opus-codec.org>

The Opus encoder (`libopus`). FFmpeg uses it when Phone Sync converts a
track to Opus. It is shipped as a separate dynamic library, unmodified, as
built by Homebrew.

BSD 3-Clause License

Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic,
                    Jean-Marc Valin, Timothy B. Terriberry,
                    CSIRO, Gregory Maxwell, Mark Borgerding,
                    Erik de Castro Lopo, Mozilla, Amazon

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Opus is subject to the royalty-free patent licenses which are
specified at:

Xiph.Org Foundation:
<https://datatracker.ietf.org/ipr/1524/>

Microsoft Corporation:
<https://datatracker.ietf.org/ipr/1914/>

Broadcom Corporation:
<https://datatracker.ietf.org/ipr/1526/>

---

## OpenSSL 3.6.5

<https://openssl-library.org>

TLS for HTTPS streams (`libssl` and `libcrypto`), used by FFmpeg.
Licensed under the **Apache License, Version 2.0**. It is shipped as
separate dynamic libraries, unmodified, as built by Homebrew.

FFmpeg's `LICENSE.md` says of OpenSSL: "To the best of our knowledge, they
are compatible with the LGPL."

The Apache 2.0 full text is available at:
<https://www.apache.org/licenses/LICENSE-2.0>

OpenSSL source code is available at <https://openssl-library.org/source/>.

---

## TagLib 2.3.2

<https://taglib.org>

Licensed under the **GNU Lesser General Public Licence, version 2.1** or, at
your option, the **Mozilla Public Licence 1.1**.

### LGPL 2.1

The LGPL 2.1 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

### Mozilla Public Licence 1.1

The MPL 1.1 full text is available at:
<https://www.mozilla.org/en-US/MPL/1.1/>

TagLib source code is available at <https://github.com/taglib/taglib>.

---

## Chromaprint / fpcalc 1.6.1

<https://acoustid.org/chromaprint>

Licensed, as a whole, under the **GNU Lesser General Public Licence, version
2.1** (LGPL 2.1). Chromaprint's own code is under the MIT licence, and it
includes parts of FFmpeg, which are under the LGPL (Chromaprint's
`LICENSE.md`).

Bòcan builds the `fpcalc` helper and `libchromaprint` itself, from the
unmodified source release named below, against the FFmpeg build described
above. Apple's Accelerate framework (vDSP) does the FFT, so no separate FFT
library is linked.

The LGPL 2.1 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

### Source and build recipe

- Source: <https://github.com/acoustid/chromaprint/releases/download/v1.6.1/chromaprint-1.6.1.tar.gz>
- SHA-256 of that file: `3368805af0ee47b9df74df10b5001a44569e01df2844dab520031720dde9ad23`
- Build recipe: `Scripts/build-fpcalc.sh` in the Bòcan source
  (<https://github.com/bocan/bocan-music>), run as `make bundle-fpcalc`.
  The version, the address and the checksum are pinned in
  `.chromaprint-source`. The CMake options are in that script.

---

## GRDB.swift 7.11.1

<https://github.com/groue/GRDB.swift>

MIT License

Copyright © 2015-2026 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## swift-snapshot-testing 1.19.6

<https://github.com/pointfreeco/swift-snapshot-testing>

MIT License

Copyright © 2019 Point-Free, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## swift-custom-dump 1.7.3

<https://github.com/pointfreeco/swift-custom-dump>

MIT License

Copyright © 2021 Point-Free, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## swift-issue-reporting 2.1.1

(formerly xctest-dynamic-overlay)

<https://github.com/pointfreeco/swift-issue-reporting>

MIT License

Copyright © 2021 Point-Free, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Sparkle 2.10.0

<https://sparkle-project.org>

MIT License

Copyright (c) 2006–2013 Andy Matuschak
Copyright (c) 2009–2013 Sparkle Project Contributors
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## SwiftSonic 0.9.0

<https://github.com/MathieuDubart/swiftsonic>

MIT License

Copyright (c) 2026 Mathieu Dubart

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## FeedKit 10.9.4

<https://github.com/nmdias/FeedKit>

Includes the XMLKit library, distributed as part of the FeedKit package under the same MIT license.

MIT License

Copyright (c) 2016 - 2025 Nuno Dias

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## swift-crypto 5.0.0

<https://github.com/apple/swift-crypto>

Cryptographic primitives for the Phone Sync feature. Licensed under the
**Apache License, Version 2.0**.

The Apache 2.0 full text is available at:
<https://www.apache.org/licenses/LICENSE-2.0>

---

## swift-certificates 1.21.0

<https://github.com/apple/swift-certificates>

X.509 certificate handling for the Phone Sync feature's mutual-TLS pairing.
Licensed under the **Apache License, Version 2.0**.

The Apache 2.0 full text is available at:
<https://www.apache.org/licenses/LICENSE-2.0>

---

## swift-asn1 1.7.3

<https://github.com/apple/swift-asn1>

ASN.1 encoding underneath swift-certificates. Licensed under the
**Apache License, Version 2.0**.

The Apache 2.0 full text is available at:
<https://www.apache.org/licenses/LICENSE-2.0>

---

## Podcast Index API

This product uses the Podcast Index API (<https://podcastindex.org>). Use of the Podcast Index API is subject to the Podcast Index API Terms of Service.

---

## Apple iTunes Search API

This product uses the Apple iTunes Search API. Use of the Apple iTunes Search API is subject to Apple's usage guidelines.

---

*This file was generated for Bòcan 2.19.0. The FFmpeg and Chromaprint
versions are pinned in `.ffmpeg-source` and `.chromaprint-source`; the Swift
package versions are pinned in the workspace `Package.resolved`.*
