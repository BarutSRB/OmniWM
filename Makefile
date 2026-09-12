.PHONY: setup doctor format format-check lint lint-fix build run dev-install use-dev use-release test-dev-tools energy-profile test-skylight-live release-check verify check check-tool-versions check-swiftformat-version check-swiftlint-version

include Scripts/dev-tools.env

export PATH := $(CURDIR)/.cache/dev-tools/bin:$(PATH)
SWIFT_WITH_GHOSTTY = LIBRARY_PATH="$$(./Scripts/ghostty-preflight.sh print-library-dir)$${LIBRARY_PATH:+:$$LIBRARY_PATH}"

setup:
	./Scripts/dev-tools.sh setup

doctor:
	./Scripts/dev-tools.sh doctor

check-swiftformat-version:
	@actual="$$(swiftformat --version 2>/dev/null || true)"; if [ "$$actual" != "$(SWIFTFORMAT_VERSION)" ]; then echo "error: SwiftFormat $(SWIFTFORMAT_VERSION) required; found $${actual:-missing}" >&2; exit 1; fi

check-swiftlint-version:
	@actual="$$(swiftlint version 2>/dev/null || true)"; if [ "$$actual" != "$(SWIFTLINT_VERSION)" ]; then echo "error: SwiftLint $(SWIFTLINT_VERSION) required; found $${actual:-missing}" >&2; exit 1; fi

check-tool-versions: check-swiftformat-version check-swiftlint-version

format: check-swiftformat-version
	swiftformat .

format-check: check-swiftformat-version
	swiftformat --lint .

lint: check-swiftlint-version
	swiftlint lint

lint-fix: check-tool-versions
	swiftformat .
	swiftlint lint --fix || true
	swiftformat .
	swiftlint lint

build:
	./Scripts/ghostty-preflight.sh verify
	$(SWIFT_WITH_GHOSTTY) swift build --arch arm64

run: dev-install

dev-install:
	./Scripts/omniwm-dev.sh install

use-dev:
	./Scripts/omniwm-dev.sh use dev

use-release:
	./Scripts/omniwm-dev.sh use release

test-dev-tools:
	python3 -m unittest discover -s Tests/DevToolingTests

energy-profile:
	./Scripts/energy-profile.sh

test-skylight-live:
	OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1 swift test --filter SkyLightNativeSpaceInventoryLiveTests/testLiveTransactionMoveIsObservedThroughWindowServerBounds

release-check: build

verify: format-check lint build

check: verify
