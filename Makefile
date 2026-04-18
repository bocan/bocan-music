.PHONY: help bootstrap doctor open build test test-coverage lint format install-hooks clean

## help: Print all available targets
help:
	@grep -E '^## [a-zA-Z_-]+:' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ": "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' | \
		sed 's/## //'

## bootstrap: Install all tools and git hooks
bootstrap: brew-bundle install-hooks
	@echo "✓ Bootstrap complete. Run 'make doctor' to verify."

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
	xcodebuild \
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
	xcodebuild \
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

## uitest: Run UI smoke tests (requires app to be built)
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
