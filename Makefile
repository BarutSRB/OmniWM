.PHONY: format lint lint-fix no-zig-audit build test verify check

SWIFT_ONLY_BASE = 6fde9b910a6dd531eeaf3892499729120ae75f49
SWIFT_WITH_GHOSTTY = LIBRARY_PATH="$$(./Scripts/ghostty-preflight.sh print-library-dir)$${LIBRARY_PATH:+:$$LIBRARY_PATH}"

format:
	swiftformat .

lint:
	swiftlint lint

lint-fix:
	swiftlint lint --fix

no-zig-audit:
	./Scripts/audit-no-zig.sh --range "$(SWIFT_ONLY_BASE)..HEAD"
	./Scripts/audit-no-zig.sh --staged
	./Scripts/audit-no-zig.sh --worktree

build:
	./Scripts/ghostty-preflight.sh verify
	$(SWIFT_WITH_GHOSTTY) swift build

test:
	./Scripts/ghostty-preflight.sh verify
	$(SWIFT_WITH_GHOSTTY) swift test

verify: lint no-zig-audit build test

check: verify
