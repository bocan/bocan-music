# SwiftLint and SwiftFormat exact versions are pinned in `.swiftlint-version`
# and `.swiftformat-version`: CI installs those releases (shadowing these brew
# copies) and `make doctor` fails on a mismatch. Lint/format behaviour shifts
# between patch releases (SwiftLint force_unwrapping/superfluous_disable;
# SwiftFormat redundantSendable and conditional-body wrapping), so an unpinned
# local copy silently diverges from CI and reformats unrelated files. Match the
# pins locally.
brew "swiftlint"
brew "swiftformat"
brew "xcbeautify"
brew "gitleaks"    # secret scan in the pre-commit hook; CI pins its own copy
# FFmpeg and Chromaprint are NOT here, on purpose (ADR-096). Homebrew's
# `ffmpeg` is a GPLv3 build with libx264 and libx265, and Homebrew's
# `chromaprint` depends on it. The project builds both from source under the
# LGPL: `make ffmpeg-lgpl` (pinned in `.ffmpeg-source`) and `make
# bundle-fpcalc` (pinned in `.chromaprint-source`). Do not add them back. If
# another tool on your machine installs Homebrew's ffmpeg, that is harmless:
# no build setting looks at it, and a test fails if one ever does.
#
# What those two source builds need:
brew "lame"       # MP3 encoder for Phone Sync transcodes (LGPL-2.0-or-later)
brew "opus"       # Opus encoder for Phone Sync transcodes (BSD-3-Clause)
brew "openssl@3"  # TLS for https streams (Apache-2.0)
brew "pkgconf"    # FFmpeg's configure finds opus and openssl through it
brew "cmake"      # builds Chromaprint
# TagLib >= 2.2 (the Swift bindings need the MP4ItemFactory APIs).
brew "taglib"
brew "create-dmg"
brew "gh"
brew "xcodegen"  # generates Bocan.xcodeproj from project.yml
