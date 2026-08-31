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
# Phase 1 audit #26: bocan-music links against FFmpeg, Chromaprint, and
# TagLib at fixed major versions.  Homebrew formulae do not pin cleanly
# (Homebrew refuses old bottles after a few months).  The FFmpeg major is
# pinned in `.ffmpeg-major` and ENFORCED by `make doctor` (also run in CI)
# via Scripts/check-ffmpeg-major.sh, which additionally fails when the
# bundled fpcalc dylibs under Resources/ drift from the installed majors.
# Expected major versions:
#   ffmpeg     == .ffmpeg-major  (bump deliberately: update the pin, re-run
#                                 'make bundle-fpcalc', run the full suites)
#   chromaprint >= 1.6 (fpcalc CLI flags assumed by the wrapper)
#   taglib     >= 2.2 (Swift bindings need MP4ItemFactory APIs)
brew "ffmpeg"
brew "chromaprint"
brew "taglib"
brew "create-dmg"
brew "gh"
brew "xcodegen"  # generates Bocan.xcodeproj from project.yml
