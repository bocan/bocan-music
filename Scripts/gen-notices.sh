#!/bin/bash
set -euo pipefail

# Regenerate NOTICES.md with current dependency versions from Homebrew and
# the workspace Package.resolved.
#
# Usage: ./Scripts/gen-notices.sh
#
# This script:
# 1. Extracts the app version from Resources/Info.plist
# 2. Queries installed versions from Homebrew (ffmpeg, chromaprint, taglib)
# 3. Extracts SPM versions from the workspace Package.resolved (the single
#    source of truth for what builds actually link; per-module resolved
#    files are uncommitted side effects of local test runs)
# 4. Rewrites NOTICES.md with current versions and the license texts below
#
# A missing pin is a hard error: silent fallbacks to hardcoded versions are
# how this file drifted from reality once already.
#
# Run this after updating dependencies or before releases.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_PATH="${REPO_ROOT}/Resources/Info.plist"
NOTICES_PATH="${REPO_ROOT}/NOTICES.md"
RESOLVED_PATH="${REPO_ROOT}/Bocan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# Extract version from Info.plist CFBundleShortVersionString
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${PLIST_PATH}")
echo "📦 App version: ${APP_VERSION}"

# Get installed versions from Homebrew
FFMPEG_VERSION=$(brew list --versions ffmpeg 2>/dev/null | awk '{print $2}' || echo "unknown")
CHROMAPRINT_VERSION=$(brew list --versions chromaprint 2>/dev/null | awk '{print $2}' || echo "unknown")
TAGLIB_VERSION=$(brew list --versions taglib 2>/dev/null | awk '{print $2}' || echo "unknown")

echo "📌 Dependency versions:"
echo "  - FFmpeg: ${FFMPEG_VERSION}"
echo "  - Chromaprint: ${CHROMAPRINT_VERSION}"
echo "  - TagLib: ${TAGLIB_VERSION}"

# Extract an SPM pin version from the workspace Package.resolved by identity.
# Hard-fails when the pin is absent so a rename or removal upstream cannot
# silently print a stale number.
extract_spm_version() {
    local identity="$1"
    python3 - "$RESOLVED_PATH" "$identity" << 'PY'
import json
import sys

path, identity = sys.argv[1], sys.argv[2]
pins = json.load(open(path))["pins"]
for pin in pins:
    if pin["identity"] == identity:
        print(pin["state"]["version"])
        break
else:
    sys.exit(f"error: no pin with identity '{identity}' in {path}")
PY
}

GRDB_VERSION=$(extract_spm_version "grdb.swift")
SNAPSHOT_VERSION=$(extract_spm_version "swift-snapshot-testing")
CUSTOM_DUMP_VERSION=$(extract_spm_version "swift-custom-dump")
XCTEST_VERSION=$(extract_spm_version "xctest-dynamic-overlay")
SPARKLE_VERSION=$(extract_spm_version "sparkle")
SWIFTSONIC_VERSION=$(extract_spm_version "swiftsonic")
FEEDKIT_VERSION=$(extract_spm_version "feedkit")
CRYPTO_VERSION=$(extract_spm_version "swift-crypto")
CERTIFICATES_VERSION=$(extract_spm_version "swift-certificates")
ASN1_VERSION=$(extract_spm_version "swift-asn1")

echo "  - GRDB: ${GRDB_VERSION}"
echo "  - swift-snapshot-testing: ${SNAPSHOT_VERSION}"
echo "  - swift-custom-dump: ${CUSTOM_DUMP_VERSION}"
echo "  - xctest-dynamic-overlay: ${XCTEST_VERSION}"
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

Bòcan links against FFmpeg libraries built **without any GPL or non-free
components**, making them available under the GNU Lesser General Public Licence,
version 2.1 or later (LGPL 2.1+).

The LGPL 2.1 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

FFmpeg source code is available at <https://ffmpeg.org/download.html>.
The Homebrew formula used to build the bundled dylibs is
\`homebrew-core/Formula/f/ffmpeg.rb\`.

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

Licensed under the **GNU Lesser General Public Licence, version 2.1 or later**
(LGPL 2.1+).

The LGPL 2.1 full text is available at:
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

Chromaprint source code is available at
<https://github.com/acoustid/chromaprint>.

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

## xctest-dynamic-overlay ${XCTEST_VERSION}

<https://github.com/pointfreeco/xctest-dynamic-overlay>

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

*This file was generated for Bòcan ${APP_VERSION}. Dependency versions are pinned in
the workspace \`Package.resolved\`.*
EOF

echo "✅ Generated ${NOTICES_PATH}"
