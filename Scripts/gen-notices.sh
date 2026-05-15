#!/bin/bash
set -euo pipefail

# Regenerate NOTICES.md with current dependency versions from Homebrew and Package.resolved.
#
# Usage: ./Scripts/gen-notices.sh
#
# This script:
# 1. Extracts the app version from Resources/Info.plist
# 2. Queries installed versions from Homebrew (ffmpeg, chromaprint, taglib)
# 3. Extracts SPM versions from Package.resolved files
# 4. Updates NOTICES.md with current versions while preserving license text
#
# Run this after updating dependencies or before releases.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_PATH="${REPO_ROOT}/Resources/Info.plist"
NOTICES_PATH="${REPO_ROOT}/NOTICES.md"

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

# Extract SPM versions from Package.resolved files using swift package describe
# (fallback to known versions if jq/parsing fails)
extract_spm_version() {
    local package_name="$1"
    local module_path="$2"
    
    if [[ ! -f "${module_path}/Package.resolved" ]]; then
        return
    fi
    
    # Try to extract from Package.resolved JSON using grep+sed
    grep -i "\"identity\"\s*:\s*\".*${package_name}\"" "${module_path}/Package.resolved" 2>/dev/null | head -1 | \
        grep -o '"version"\s*:\s*"[^"]*"' | cut -d'"' -f4 || true
}

# Extract SPM versions
GRDB_VERSION=$(extract_spm_version "grdb" "${REPO_ROOT}/Modules/Persistence")
SNAPSHOT_VERSION=$(extract_spm_version "snapshot-testing" "${REPO_ROOT}/Modules/UI")
CUSTOM_DUMP_VERSION=$(extract_spm_version "custom-dump" "${REPO_ROOT}/Modules/UI")
XCTEST_VERSION=$(extract_spm_version "xctest-dynamic-overlay" "${REPO_ROOT}/Modules/UI")
SPARKLE_VERSION=$(extract_spm_version "sparkle" "${REPO_ROOT}")

# Fallback to known versions if extraction failed
GRDB_VERSION=${GRDB_VERSION:-7.10.0}
SNAPSHOT_VERSION=${SNAPSHOT_VERSION:-1.19.2}
CUSTOM_DUMP_VERSION=${CUSTOM_DUMP_VERSION:-1.5.0}
XCTEST_VERSION=${XCTEST_VERSION:-1.9.0}
SPARKLE_VERSION=${SPARKLE_VERSION:-2.9.1}

echo "  - GRDB: ${GRDB_VERSION}"
echo "  - swift-snapshot-testing: ${SNAPSHOT_VERSION}"
echo "  - swift-custom-dump: ${CUSTOM_DUMP_VERSION}"
echo "  - xctest-dynamic-overlay: ${XCTEST_VERSION}"
echo "  - Sparkle: ${SPARKLE_VERSION}"

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

*This file was generated for Bòcan ${APP_VERSION}. Dependency versions are pinned in
each module's \`Package.resolved\`.*
EOF

echo "✅ Generated ${NOTICES_PATH}"
