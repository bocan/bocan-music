brew "swiftlint"
brew "swiftformat"
brew "xcbeautify"
# Phase 1 audit #26: bocan-music links against FFmpeg, Chromaprint, and
# TagLib at fixed major versions.  Homebrew formulae do not pin cleanly
# (Homebrew refuses old bottles after a few months), so we surface drift
# at runtime via `make doctor`.  Expected major versions:
#   ffmpeg     >= 8   (uses lavfi sine, libopus, wavpack codec ids)
#   chromaprint >= 1.6 (fpcalc CLI flags assumed by the wrapper)
#   taglib     >= 2.2 (Swift bindings need MP4ItemFactory APIs)
brew "ffmpeg"
brew "chromaprint"
brew "taglib"
brew "create-dmg"
brew "gh"
brew "xcodegen"  # generates Bocan.xcodeproj from project.yml
