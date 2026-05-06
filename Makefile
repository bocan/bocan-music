.PHONY: help bootstrap bundle-fpcalc embed-deps brew-bundle doctor open generate build tests test test-coverage test-audio-engine test-persistence test-metadata test-library test-acoustics test-ui uitest lint format format-check install-hooks clean

## tests: Run format, lint, full test matrix (Xcode + every SPM module)
tests: format lint build test test-coverage test-audio-engine test-persistence test-metadata test-library test-acoustics test-ui

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
		test \
		| xcbeautify
	Scripts/coverage-report.sh build/TestResults.xcresult 80

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
