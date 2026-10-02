#!/bin/bash
set -euo pipefail

# Regenerate NOTICES.md with current dependency versions from the two source
# pins, Homebrew and the workspace Package.resolved.
#
# Usage: ./Scripts/gen-notices.sh
#
# This script:
# 1. Extracts the app version from Resources/Info.plist
# 2. Reads the FFmpeg and Chromaprint versions and source URLs from
#    .ffmpeg-source and .chromaprint-source, the pins that
#    Scripts/build-ffmpeg-lgpl.sh and Scripts/build-fpcalc.sh build from
#    (ADR-096). Homebrew's ffmpeg and chromaprint are not used and are not
#    asked.
# 3. Copies the FFmpeg configure line out of Scripts/build-ffmpeg-lgpl.sh,
#    so the notice cannot say something the build does not do
# 4. Queries Homebrew for the installed versions of the libraries that still
#    come from it (taglib, lame, opus, openssl@3, mpg123)
# 5. Extracts SPM versions from the workspace Package.resolved (the single
#    source of truth for what builds actually link; per-module resolved
#    files are uncommitted side effects of local test runs)
# 6. Rewrites NOTICES.md with current versions and the license texts below
#
# A missing pin is a hard error: silent fallbacks to hardcoded versions are
# how this file drifted from reality once already.
#
# Run this after updating dependencies or before releases.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_PATH="${REPO_ROOT}/Resources/Info.plist"
NOTICES_PATH="${REPO_ROOT}/NOTICES.md"
RESOLVED_PATH="${REPO_ROOT}/Bocan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
FFMPEG_PIN_PATH="${REPO_ROOT}/.ffmpeg-source"
CHROMAPRINT_PIN_PATH="${REPO_ROOT}/.chromaprint-source"
FFMPEG_BUILD_SCRIPT="${REPO_ROOT}/Scripts/build-ffmpeg-lgpl.sh"

fail() {
    echo "error: $1" >&2
    exit 1
}

# Extract version from Info.plist CFBundleShortVersionString
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${PLIST_PATH}")
echo "📦 App version: ${APP_VERSION}"

# Read one KEY=value from a pin file. The file is not sourced, so it cannot
# run code here. A missing key is a hard error.
read_pin() {
    local file="$1" key="$2" value
    [[ -f "$file" ]] || fail "$file is missing."
    value="$(sed -nE "s/^${key}=(.*)\$/\1/p" "$file" | head -1)"
    [[ -n "$value" ]] || fail "$file does not set $key."
    echo "$value"
}

FFMPEG_VERSION=$(read_pin "$FFMPEG_PIN_PATH" FFMPEG_VERSION)
FFMPEG_URL=$(read_pin "$FFMPEG_PIN_PATH" FFMPEG_URL)
FFMPEG_SHA256=$(read_pin "$FFMPEG_PIN_PATH" FFMPEG_SHA256)
CHROMAPRINT_VERSION=$(read_pin "$CHROMAPRINT_PIN_PATH" CHROMAPRINT_VERSION)
CHROMAPRINT_URL=$(read_pin "$CHROMAPRINT_PIN_PATH" CHROMAPRINT_URL)
CHROMAPRINT_SHA256=$(read_pin "$CHROMAPRINT_PIN_PATH" CHROMAPRINT_SHA256)

# The FFmpeg configure line, copied from the CONFIGURE_ARGS array of the build
# script with its comment lines left out. The shell variables stay as written
# ($PREFIX and so on); the notice says what each one holds.
[[ -f "$FFMPEG_BUILD_SCRIPT" ]] || fail "$FFMPEG_BUILD_SCRIPT is missing."
FFMPEG_CONFIGURE_LINE="$(awk '
    /^CONFIGURE_ARGS=\(/ { inside = 1; next }
    inside && /^\)/      { inside = 0 }
    inside && $1 !~ /^#/ { sub(/^[[:space:]]+/, ""); print "  " $0 " \\" }
' "$FFMPEG_BUILD_SCRIPT" | sed '$ s/ \\$//')"
[[ "$FFMPEG_CONFIGURE_LINE" == *"--enable-shared"* ]] \
    || fail "could not read CONFIGURE_ARGS from $FFMPEG_BUILD_SCRIPT."
# The notice below states an LGPL v2.1-or-later build. Refuse to write that
# over a configure line that asks for something else.
if grep -q -E -- '--enable-(gpl|version3|nonfree)( |$)' <<< "$FFMPEG_CONFIGURE_LINE"; then
    fail "the configure line in $FFMPEG_BUILD_SCRIPT asks for the GPL, version 3 or nonfree code."
fi

# The installed version of a Homebrew formula. Not installed is a hard error.
brew_version() {
    local version
    version="$(brew list --versions "$1" 2>/dev/null | awk '{print $2}' || true)"
    [[ -n "$version" ]] || fail "Homebrew formula $1 is not installed. Run: brew bundle"
    echo "$version"
}

TAGLIB_VERSION=$(brew_version taglib)
LAME_VERSION=$(brew_version lame)
OPUS_VERSION=$(brew_version opus)
OPENSSL_VERSION=$(brew_version openssl@3)
# Homebrew's lame links libmpg123, so libmpg123 is bundled with it. If a later
# lame formula drops that dependency, remove the mpg123 section and this line.
MPG123_VERSION=$(brew_version mpg123)

echo "📌 Dependency versions:"
echo "  - FFmpeg: ${FFMPEG_VERSION} (.ffmpeg-source)"
echo "  - Chromaprint: ${CHROMAPRINT_VERSION} (.chromaprint-source)"
echo "  - TagLib: ${TAGLIB_VERSION}"
echo "  - LAME: ${LAME_VERSION}"
echo "  - Opus: ${OPUS_VERSION}"
echo "  - OpenSSL: ${OPENSSL_VERSION}"
echo "  - mpg123: ${MPG123_VERSION}"

# Extract an SPM pin version from the workspace Package.resolved by identity.
# Takes one or more identities and uses the first that resolves, so a package
# renamed upstream can be found under either name while the toolchains
# disagree about which one to write. Still hard-fails when none of them is
# present, so a rename or removal cannot silently print a stale number.
extract_spm_version() {
    python3 - "$RESOLVED_PATH" "$@" << 'PY'
import json
import sys

path, identities = sys.argv[1], sys.argv[2:]
pins = {pin["identity"]: pin["state"]["version"] for pin in json.load(open(path))["pins"]}
for identity in identities:
    if identity in pins:
        print(pins[identity])
        sys.exit(0)
sys.exit(f"error: no pin in {path} with any of these identities: {', '.join(identities)}")
PY
}

GRDB_VERSION=$(extract_spm_version "grdb.swift")
SNAPSHOT_VERSION=$(extract_spm_version "swift-snapshot-testing")
CUSTOM_DUMP_VERSION=$(extract_spm_version "swift-custom-dump")
# Point-Free renamed xctest-dynamic-overlay to swift-issue-reporting. Xcode 27
# follows the rename when it resolves; 26.6 still writes the old identity.
ISSUE_REPORTING_VERSION=$(extract_spm_version "swift-issue-reporting" "xctest-dynamic-overlay")
SPARKLE_VERSION=$(extract_spm_version "sparkle")
SWIFTSONIC_VERSION=$(extract_spm_version "swiftsonic")
FEEDKIT_VERSION=$(extract_spm_version "feedkit")
CRYPTO_VERSION=$(extract_spm_version "swift-crypto")
CERTIFICATES_VERSION=$(extract_spm_version "swift-certificates")
ASN1_VERSION=$(extract_spm_version "swift-asn1")

echo "  - GRDB: ${GRDB_VERSION}"
echo "  - swift-snapshot-testing: ${SNAPSHOT_VERSION}"
echo "  - swift-custom-dump: ${CUSTOM_DUMP_VERSION}"
echo "  - swift-issue-reporting: ${ISSUE_REPORTING_VERSION}"
echo "  - Sparkle: ${SPARKLE_VERSION}"
echo "  - SwiftSonic: ${SWIFTSONIC_VERSION}"
echo "  - FeedKit: ${FEEDKIT_VERSION}"
echo "  - swift-crypto: ${CRYPTO_VERSION}"
echo "  - swift-certificates: ${CERTIFICATES_VERSION}"
echo "  - swift-asn1: ${ASN1_VERSION}"

# Build the file by replacing version placeholders in the existing template sections
cat > "${NOTICES_PATH}" << EOF
# Third-Party Notices

Bòcan incorporates the following open-source components. Full licence texts are
reproduced below as required by each project's terms.

---

## FFmpeg ${FFMPEG_VERSION}

<https://ffmpeg.org>

Licensed under the **GNU Lesser General Public Licence, version 2.1 or later**
(LGPL 2.1+).

Bòcan builds FFmpeg itself, from the unmodified source release named below,
and configures it with none of \`--enable-gpl\`, \`--enable-version3\` and
\`--enable-nonfree\`. FFmpeg's own \`LICENSE.md\` says that in this
configuration the LGPL v2.1 or later applies to FFmpeg, and each built
library reports "LGPL version 2.1 or later". The release build stops if a
bundled FFmpeg library reports anything else
(\`Scripts/check-bundle-licence.sh\`).

The app ships four FFmpeg libraries, as separate dynamic libraries:
\`libavcodec\`, \`libavformat\`, \`libavutil\` and \`libswresample\`. There is
one copy in \`Contents/Frameworks\` and one copy beside the \`fpcalc\` helper
in \`Contents/Resources\`.

The LGPL 2.1 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

### Source and build recipe

- Source: <${FFMPEG_URL}>
- SHA-256 of that file: \`${FFMPEG_SHA256}\`
- Build recipe: \`Scripts/build-ffmpeg-lgpl.sh\` in the Bòcan source
  (<https://github.com/bocan/bocan-music>), run as \`make ffmpeg-lgpl\`. The
  version, the address and the checksum are pinned in \`.ffmpeg-source\`.

The script runs this configure line, then \`make\` and \`make install\`:

\`\`\`bash
./configure \\
${FFMPEG_CONFIGURE_LINE}
\`\`\`

\`\$PREFIX\` is the directory the libraries are installed into
(\`build/ffmpeg-lgpl\` by default). \`\$DEPLOYMENT_TARGET\` is the oldest
macOS the app runs on (15.0). \`\$LAME_PREFIX\` is the Homebrew directory of
the LAME library.

### External libraries in this build

The configure line turns autodetection off, so the build links only the
libraries it names: LAME, Opus and OpenSSL (each has its own section below),
the zlib and bzip2 libraries that come with macOS, and Apple's AudioToolbox
framework.

### Independent JPEG Group

Three files in \`libavcodec\` (\`jfdctfst.c\`, \`jfdctint_template.c\` and
\`jrevdct.c\`) come from libjpeg. This software is based in part on the work
of the Independent JPEG Group.

---

## LAME ${LAME_VERSION}

<https://lame.sourceforge.io>

The MP3 encoder (\`libmp3lame\`). FFmpeg uses it when Phone Sync converts a
track to MP3. Licensed under the **GNU Library General Public Licence,
version 2 or later** (LGPL 2.0+). It is shipped as a separate dynamic
library, unmodified, as built by Homebrew.

The LGPL 2.0 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html>

LAME source code is available at <https://lame.sourceforge.io>.

---

## mpg123 ${MPG123_VERSION}

<https://www.mpg123.de>

\`libmpg123\` is shipped because Homebrew's build of LAME links it. Licensed
under the **GNU Lesser General Public Licence, version 2.1**. It is shipped
as a separate dynamic library, unmodified, as built by Homebrew.

The LGPL 2.1 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

mpg123 source code is available at <https://www.mpg123.de/download/>.

---

## Opus ${OPUS_VERSION}

<https://opus-codec.org>

The Opus encoder (\`libopus\`). FFmpeg uses it when Phone Sync converts a
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
\`\`AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
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

## OpenSSL ${OPENSSL_VERSION}

<https://openssl-library.org>

TLS for HTTPS streams (\`libssl\` and \`libcrypto\`), used by FFmpeg.
Licensed under the **Apache License, Version 2.0**. It is shipped as
separate dynamic libraries, unmodified, as built by Homebrew.

FFmpeg's \`LICENSE.md\` says of OpenSSL: "To the best of our knowledge, they
are compatible with the LGPL."

The Apache 2.0 full text is available at:
<https://www.apache.org/licenses/LICENSE-2.0>

OpenSSL source code is available at <https://openssl-library.org/source/>.

---

## TagLib ${TAGLIB_VERSION}

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

## Chromaprint / fpcalc ${CHROMAPRINT_VERSION}

<https://acoustid.org/chromaprint>

Licensed, as a whole, under the **GNU Lesser General Public Licence, version
2.1** (LGPL 2.1). Chromaprint's own code is under the MIT licence, and it
includes parts of FFmpeg, which are under the LGPL (Chromaprint's
\`LICENSE.md\`).

Bòcan builds the \`fpcalc\` helper and \`libchromaprint\` itself, from the
unmodified source release named below, against the FFmpeg build described
above. Apple's Accelerate framework (vDSP) does the FFT, so no separate FFT
library is linked.

The LGPL 2.1 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

### Source and build recipe

- Source: <${CHROMAPRINT_URL}>
- SHA-256 of that file: \`${CHROMAPRINT_SHA256}\`
- Build recipe: \`Scripts/build-fpcalc.sh\` in the Bòcan source
  (<https://github.com/bocan/bocan-music>), run as \`make bundle-fpcalc\`.
  The version, the address and the checksum are pinned in
  \`.chromaprint-source\`. The CMake options are in that script.

---

## GRDB.swift ${GRDB_VERSION}

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

## swift-snapshot-testing ${SNAPSHOT_VERSION}

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

## swift-custom-dump ${CUSTOM_DUMP_VERSION}

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

## swift-issue-reporting ${ISSUE_REPORTING_VERSION}

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

## Sparkle ${SPARKLE_VERSION}

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

## SwiftSonic ${SWIFTSONIC_VERSION}

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

## FeedKit ${FEEDKIT_VERSION}

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

## swift-crypto ${CRYPTO_VERSION}

<https://github.com/apple/swift-crypto>

Cryptographic primitives for the Phone Sync feature. Licensed under the
**Apache License, Version 2.0**.

The Apache 2.0 full text is available at:
<https://www.apache.org/licenses/LICENSE-2.0>

---

## swift-certificates ${CERTIFICATES_VERSION}

<https://github.com/apple/swift-certificates>

X.509 certificate handling for the Phone Sync feature's mutual-TLS pairing.
Licensed under the **Apache License, Version 2.0**.

The Apache 2.0 full text is available at:
<https://www.apache.org/licenses/LICENSE-2.0>

---

## swift-asn1 ${ASN1_VERSION}

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

*This file was generated for Bòcan ${APP_VERSION}. The FFmpeg and Chromaprint
versions are pinned in \`.ffmpeg-source\` and \`.chromaprint-source\`; the Swift
package versions are pinned in the workspace \`Package.resolved\`.*
EOF

echo "✅ Generated ${NOTICES_PATH}"
