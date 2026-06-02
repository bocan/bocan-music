.PHONY: help bootstrap bundle-fpcalc embed-deps brew-bundle doctor open generate build tests test test-coverage coverage-all test-audio-engine test-persistence test-metadata test-library test-acoustics test-ui test-playback test-scrobble test-subsonic test-observability uitest lint format format-check install-hooks clean

# Pinned SwiftLint version. CI installs this exact release; `doctor` fails when
# the local install differs. SwiftLint's force_unwrapping/superfluous_disable
# behaviour changed between patch releases (0.63.2 vs 0.63.3), so an unpinned
# version silently diverges local from CI. Single source of truth: bump the
# `.swiftlint-version` file and CI follows automatically.
EXPECTED_SWIFTLINT := $(shell cat .swiftlint-version 2>/dev/null)

# Extra xcodebuild settings injected into `build`/`test`/`test-coverage`. Empty by
# default. CI uses it to strip the keychain-access-groups entitlement on unsigned
# ad-hoc builds (which otherwise demand a provisioning profile):
#   make test-coverage XCB_OVERRIDE='CODE_SIGN_ENTITLEMENTS='
XCB_OVERRIDE ?=

## tests: Run format, lint, full test matrix — one line per stage, errors shown inline
tests:
	@bash Scripts/run-tests.sh

## help: Print all available targets
help:
	@grep -E '^## [a-zA-Z_-]+:' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ": "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' | \
		sed 's/## //'

## bootstrap: Install all tools and git hooks
bootstrap: brew-bundle install-hooks bundle-fpcalc
	@echo "✓ Bootstrap complete. Run 'make doctor' to verify."

## bundle-fpcalc: Copy fpcalc + FFmpeg dylibs from Homebrew into Resources/ and relink
bundle-fpcalc:
	bash Scripts/build-fpcalc.sh
	xcodegen generate

## embed-deps: Bundle TagLib/FFmpeg dylibs into a built Bocan.app (post-export; ad-hoc sign)
## Usage: make embed-deps APP=build/export/Bocan.app
embed-deps:
	bash Scripts/embed-deps.sh "$(APP)"

## brew-bundle: Install Brewfile dependencies
brew-bundle:
	brew bundle

## doctor: Print tool versions (also run in CI)
doctor:
	@echo "=== Bòcan dev environment ==="
	@swift --version
	@xcodebuild -version | head -1
	@swiftlint version
	@swiftformat --version
	@xcbeautify --version
	@xcodegen --version
	@gh --version | head -1
	@printf 'ffmpeg     '; ffmpeg -version 2>/dev/null | head -1 || echo '(missing)'
	@printf 'fpcalc     '; fpcalc -version 2>/dev/null | head -1 || echo '(missing)'
	@printf 'taglib     '; pkg-config --modversion taglib 2>/dev/null || echo '(missing)'
	@echo "=============================="
	@if [ ! -f Brewfile.lock.json ]; then \
		echo "⚠️  WARNING: Brewfile.lock.json is missing. Run 'brew bundle install' then commit the lock file."; \
	fi
	@actual="$$(swiftlint version 2>/dev/null)"; \
	if [ -z "$(EXPECTED_SWIFTLINT)" ]; then \
		echo "⚠️  WARNING: .swiftlint-version is missing; cannot verify the SwiftLint pin."; \
	elif [ "$$actual" != "$(EXPECTED_SWIFTLINT)" ]; then \
		echo "✗ SwiftLint version mismatch: have '$$actual', expected '$(EXPECTED_SWIFTLINT)' (.swiftlint-version)."; \
		echo "  CI pins this exact release; lint results diverge across SwiftLint versions."; \
		echo "  Install the pinned version, e.g.:  curl -sSL https://github.com/realm/SwiftLint/releases/download/$(EXPECTED_SWIFTLINT)/portable_swiftlint.zip -o /tmp/sl.zip && unzip -o /tmp/sl.zip swiftlint -d /opt/homebrew/bin"; \
		exit 1; \
	else \
		echo "✓ SwiftLint $$actual matches the pin"; \
	fi

## open: Open the Xcode project
open:
	@open Bocan.xcodeproj

## generate: Regenerate Bocan.xcodeproj from project.yml
generate:
	xcodegen generate

## build: Build the Debug configuration
build:
	xcodebuild \
		-project Bocan.xcodeproj \
		-scheme Bocan \
		-configuration Debug \
		-destination 'platform=macOS' \
		$(XCB_OVERRIDE) \
		build \
		| xcbeautify

## test: Run unit + integration tests (excludes UITests)
test:
	@echo "=============================="
	@echo "= Executing Xcode Test"
	@echo "=============================="
	rm -rf build/TestResults.xcresult
	set -o pipefail && xcodebuild \
		-project Bocan.xcodeproj \
		-scheme Bocan \
		-configuration Debug \
		-destination 'platform=macOS' \
		-resultBundlePath build/TestResults.xcresult \
		-skip-testing:BocanUITests \
		$(XCB_OVERRIDE) \
		test \
		| xcbeautify

## test-coverage: Run tests and fail if coverage < 80%
test-coverage:
	@echo "=============================="
	@echo "= Executing Coverage Test"
	@echo "=============================="
	rm -rf build/TestResults.xcresult
	set -o pipefail && xcodebuild \
		-project Bocan.xcodeproj \
		-scheme Bocan \
		-configuration Debug \
		-destination 'platform=macOS' \
		-resultBundlePath build/TestResults.xcresult \
		-enableCodeCoverage YES \
		-skip-testing:BocanUITests \
		$(XCB_OVERRIDE) \
		test \
		| xcbeautify
	Scripts/coverage-report.sh build/TestResults.xcresult 80

## coverage-all: Run SPM module tests with coverage and fail if any module is below threshold
## Defaults to 70%. Override with COVERAGE_THRESHOLD=NN for a global
## floor, or COVERAGE_MIN_<MODULE>=NN for a per-module floor (e.g. COVERAGE_MIN_UI=20).
coverage-all:
	@echo "=============================="
	@echo "= Per-module Coverage Gate"
	@echo "=============================="
	COVERAGE_MIN_UI=$(or $(COVERAGE_MIN_UI),20) \
		Scripts/coverage-all.sh $(or $(COVERAGE_THRESHOLD),70)

## test-audio-engine: Run AudioEngine SPM package tests (requires FFmpeg via Homebrew)
test-audio-engine:
	@echo "=============================="
	@echo "= Executing AudioEngine Test"
	@echo "=============================="
	cd Modules/AudioEngine && swift test

## test-persistence: Run Persistence SPM package tests
test-persistence:
	@echo "=============================="
	@echo "= Executing Persistence Test"
	@echo "=============================="
	cd Modules/Persistence && swift test --enable-code-coverage

## test-metadata: Run Metadata SPM package tests
test-metadata:
	@echo "=============================="
	@echo "= Executing Metadata Test"
	@echo "=============================="
	cd Modules/Metadata && swift test --enable-code-coverage

## test-library: Run Library SPM package tests
test-library:
	@echo "=============================="
	@echo "= Executing Library Test"
	@echo "=============================="
	cd Modules/Library && swift test --enable-code-coverage

## test-acoustics: Run Acoustics SPM package tests
test-acoustics:
	@echo "=============================="
	@echo "= Executing Acoustics Test"
	@echo "=============================="
	cd Modules/Acoustics && swift test --enable-code-coverage

## test-ui: Run UI SPM package tests
test-ui:
	@echo "=============================="
	@echo "= Executing UI Test"
	@echo "=============================="
	cd Modules/UI && swift test --enable-code-coverage

## test-playback: Run Playback SPM package tests (RouteManager, QueuePlayer, GaplessScheduler, etc.)
test-playback:
	@echo "=============================="
	@echo "= Executing Playback Test"
	@echo "=============================="
	cd Modules/Playback && swift test --enable-code-coverage

## test-scrobble: Run Scrobble SPM package tests
test-scrobble:
	@echo "=============================="
	@echo "= Executing Scrobble Test"
	@echo "=============================="
	cd Modules/Scrobble && swift test --enable-code-coverage

## test-subsonic: Run Subsonic SPM package tests
test-subsonic:
	@echo "=============================="
	@echo "= Executing Subsonic Test"
	@echo "=============================="
	cd Modules/Subsonic && swift test --enable-code-coverage

## test-observability: Run Observability SPM package tests
test-observability:
	@echo "=============================="
	@echo "= Executing Observability Test"
	@echo "=============================="
	cd Modules/Observability && swift test --enable-code-coverage

## uitest: Run UI smoke tests (BocanUITests scheme target)
uitest:
	xcodebuild \
		-project Bocan.xcodeproj \
		-scheme Bocan \
		-configuration Debug \
		-destination 'platform=macOS' \
		-only-testing:BocanUITests \
		test \
		| xcbeautify

## lint: Run SwiftLint
lint:
	swiftlint lint --strict

## format: Run SwiftFormat (modifies files)
format:
	swiftformat .

## format-check: Run SwiftFormat in lint mode (CI)
format-check:
	swiftformat --lint .

## install-hooks: Install git pre-commit hook
install-hooks:
	@cp Scripts/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "✓ Pre-commit hook installed"

## clean: Remove derived data and build artefacts
clean:
	rm -rf build/ DerivedData/
	xcodebuild clean -project Bocan.xcodeproj -scheme Bocan 2>/dev/null || true
