PROJECT      = Armada.xcodeproj
DERIVED_DATA = .build
BUNDLE_ID    = io.mgcrea.armada.debug

SCHEME      ?= Armada
APP_NAME    ?= Armada
DESTINATION ?= platform=macOS

# The commit this bundle was built from, forwarded into the Info.plist through the
# ARMADA_GIT_COMMIT build setting. Xcode has no git, so an Xcode-only build leaves
# it empty and `AppInfo.commit` reads nil; every build made through here names one.
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null)
# The commit count, which is what CFBundleVersion is across the fleet: it orders
# builds. It does not identify one — that is what GIT_COMMIT is for.
GIT_COUNT  := $(shell git rev-list --count HEAD 2>/dev/null)

# The marketing version is the newest `app-v*` tag, as in bastion and cupertino.
# Before the first tag there is none, and the pbxproj's MARKETING_VERSION stands.
APP_VERSION := $(shell git describe --tags --match 'app-v*' --abbrev=0 2>/dev/null | sed 's/^app-v//')

# Each applied only when XCARGS does not already name it: CI's release job passes
# both explicitly from the tag, and a second copy on the command line would leave
# which one wins to xcodebuild's argument order.
XCARGS ?=
VERSION_ARGS := $(if $(findstring MARKETING_VERSION,$(XCARGS)),,$(if $(APP_VERSION),MARKETING_VERSION=$(APP_VERSION)))
VERSION_ARGS += $(if $(findstring CURRENT_PROJECT_VERSION,$(XCARGS)),,$(if $(GIT_COUNT),CURRENT_PROJECT_VERSION=$(GIT_COUNT)))
BUILD_ARGS = ARMADA_GIT_COMMIT=$(GIT_COMMIT) $(VERSION_ARGS) $(XCARGS)

APP_BUNDLE = $(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app

.DEFAULT_GOAL := help

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Sparkle ───────────────────────────────────────────────────────────────────
#
# The updater, vendored rather than a Swift package, pinned by version AND digest
# identically to bastion and cupertino. Fetched, never committed: Vendor/ is
# git-ignored, and a checkout reproduces the same framework from these two lines.
#
# Extracted into a throwaway directory and moved into place with `ditto`, then
# stamped, which is bastion's form rather than cupertino's `unzip -qo` in place:
# an interrupted in-place extraction leaves placeholder files where the
# framework's symlinks belong, and a Sparkle.framework without them links and
# then fails at launch. The stamp is what makes `make build` re-extract only on
# a version bump.
#
# DIVERGES from both siblings on where the tools land: Vendor/bin rather than
# .build/sparkle-cache/bin. `make clean` removes .build but not the stamp, so in
# the siblings' layout a clean leaves a stamp claiming an extraction whose
# sign_update is gone — and `make appcast` is the target that needs it.
#
# XPCServices are stripped because they exist for sandboxed hosts and Armada is
# not one; each would be one more binary `make audit` had to pardon.
SPARKLE_VERSION   ?= 2.9.6
SPARKLE_SHA256    := 8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606
SPARKLE_VENDOR    := Vendor
SPARKLE_FRAMEWORK := $(SPARKLE_VENDOR)/Sparkle.framework
SPARKLE_TOOLS     := $(SPARKLE_VENDOR)/bin
SPARKLE_STAMP     := $(SPARKLE_VENDOR)/.sparkle-$(SPARKLE_VERSION)

sparkle: $(SPARKLE_STAMP) ## Fetch the pinned Sparkle framework and verify its digest

$(SPARKLE_STAMP):
	@mkdir -p $(DERIVED_DATA)/sparkle-cache $(SPARKLE_VENDOR)
	@zip="$(DERIVED_DATA)/sparkle-cache/Sparkle-$(SPARKLE_VERSION).zip"; \
	[ -f "$$zip" ] || curl -fsSL -o "$$zip" \
		"https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-for-Swift-Package-Manager.zip"; \
	echo "$(SPARKLE_SHA256)  $$zip" | shasum -a 256 -c - >/dev/null \
		|| { echo "  Sparkle checksum mismatch — refusing to build against it"; rm -f "$$zip"; exit 1; }; \
	tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/sparkle.XXXXXX") || exit 1; \
	trap 'rm -rf "$$tmp"' EXIT INT TERM; \
	ditto -x -k "$$zip" "$$tmp" || exit 1; \
	rm -rf $(SPARKLE_FRAMEWORK) $(SPARKLE_TOOLS); \
	mkdir -p $(SPARKLE_TOOLS); \
	ditto "$$tmp/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" $(SPARKLE_FRAMEWORK) || exit 1; \
	ditto "$$tmp/bin" $(SPARKLE_TOOLS) || exit 1
	@rm -rf $(SPARKLE_FRAMEWORK)/Versions/B/XPCServices
	@rm -f $(SPARKLE_VENDOR)/.sparkle-*
	@touch $(SPARKLE_STAMP)
	@echo "  Sparkle $(SPARKLE_VERSION) in $(SPARKLE_FRAMEWORK), tools in $(SPARKLE_TOOLS)"

# Debug unless told otherwise. There is no `build-release` here any more: that name
# means "signed, notarized and shippable" in all three direct-distribution repos,
# and it lives in the root Makefile, which calls `build CONFIG=Release` with signing
# switched off and signs the result itself. A bare unsigned Release build under the
# same name was one shared runbook away from being shipped.
CONFIG ?= Debug

build: sparkle ## Build the app (CONFIG=Debug by default; the root's build-release ships)
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) $(BUILD_ARGS)

# The local packages' own suites. ArmadaMCP: its tool table, run against a fake fleet with no
# app, no config folder and no bound port. ArmadaSupervisor: the voice supervisor's stream-json
# decoding, argument lockdown, sentence chunking and shortcut rules, with no microphone, no
# panel and no spawned `claude`. `swift test` rather than `xcodebuild test`, because both
# packages are plain SwiftPM and the app target has no test bundle — a protocol and a pure
# reducer are what moved everything worth testing out of it. The app's own pure files are
# checked separately, by `unit` below.
test: ## Run the local Swift package tests
	swift test --package-path Packages/ArmadaMCP
	swift test --package-path Packages/ArmadaSupervisor

# `-f` matches this recipe's own shell as well as the app, which is why the match is
# anchored on the launched binary's absolute path: that shell's command line starts
# with /bin/sh, not with the path.
MAC_EXECUTABLE := $(abspath $(APP_BUNDLE))/Contents/MacOS/$(APP_NAME)
QUIT_TIMEOUT   ?= 40

quit: ## Quit the running app and wait for the process to go
	-@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null
	@i=0; while pgrep -qf "^$(MAC_EXECUTABLE)" && [ $$i -lt $(QUIT_TIMEOUT) ]; do \
		sleep 0.25; i=$$((i + 1)); \
	done

# `quit` first: without it `open` activates the instance that is already running and a
# fix reads as not working. xcodebuild would also be overwriting the bundle underneath
# a live process.
run: build quit ## Build and launch the app
	@app="$(APP_BUNDLE)"; open "$$app" 2>/dev/null || { sleep 1; open "$$app"; }

clean: ## Remove build products
	rm -rf $(DERIVED_DATA)

.PHONY: help sparkle build test run quit clean \
	format-swift format-swift-check swift-format-version blame-setup

# ── Formatting ────────────────────────────────────────────────────────────────

# `xcrun swift-format`, not Homebrew's SwiftFormat: it ships inside the toolchain,
# so every machine that can build the app already has it, and its lint mode
# carries 32 rules so there is no SwiftLint to install either. Config is the repo
# root's `.swift-format`, which swift-format finds by walking up from each file --
# no `--configuration` belongs here or in CI.
#
# Paths are relative to THIS makefile, because the root forwards with
# `make -C` and that chdirs first, and are spelled
# out rather than pointing `-r` at the parent. That is not tidiness: build trees
# are full of Swift, a local SwiftPM package hides its dependencies' source under
# .build/checkouts, and swift-format has no ignore file -- only
# `// swift-format-ignore-file` comments inside source -- so a recursive walk from
# above reformats other people's code. Recompute with fleet-apple-conventions'
# scripts/swift_src.py rather than editing this by hand.
SWIFT_SRC := Armada UnitChecks Packages/ArmadaMCP/Package.swift Packages/ArmadaMCP/Sources \
	Packages/ArmadaMCP/Tests Packages/ArmadaSupervisor/Package.swift \
	Packages/ArmadaSupervisor/Sources Packages/ArmadaSupervisor/Tests \
	Packages/ArmadaSpeech/Package.swift Packages/ArmadaSpeech/Sources

# swift-format's behaviour follows whichever Xcode is selected, so a toolchain
# bump can reformat the whole tree with no change to `.swift-format` and turn the
# gate red on code nobody edited. Assert it, so that day arrives as a sentence
# rather than a mystery diff.
#
# Asserted against `swift --version`, NOT `swift-format --version`. Xcode 27
# ships the formatter reporting its version as the literal string `main`, which
# no pin can ever match — measured on Xcode 27.0 (27A266a), Swift 6.4, a RELEASE
# build and not a beta, which is what this guard used to blame. The compiler
# reports properly, and it is the toolchain the formatter shipped inside that
# decides how it formats.
#
# A LIST, because CI and a developer's Mac are legitimately on different Xcodes:
# the macos-latest runner is Swift 6.3 while Xcode 27 is 6.4. Both format this
# tree identically — it was formatted under 6.3 and lints clean under 6.4 with
# --strict — so both are accepted, and a third, unverified toolchain still fires.
SWIFT_FORMAT_VERSIONS := 6.3 6.4

# The assertion is fatal in CI and before anything is rewritten. A local lint
# under an unlisted toolchain only warns: it changes no file, and CI still lints
# under a listed one. $(1) is `fail` or `warn`.
# A macro each recipe calls rather than a shared prerequisite, which make would
# run once per invocation with whichever mode reached it first.
swift_format_guard = v="$$(xcrun swift --version 2>/dev/null \
	| sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"; \
	ok=""; for w in $(SWIFT_FORMAT_VERSIONS); do \
	  case "$$v" in $$w|$$w.*) ok=1;; esac; \
	done; \
	if [ -z "$$ok" ]; then \
	  echo "Swift toolchain $${v:-unknown}, expected one of: $(SWIFT_FORMAT_VERSIONS) — the toolchain moved."; \
	  if [ -n "$$CI" ] || [ "$(1)" != warn ]; then \
	    echo "Reformat deliberately and add it to SWIFT_FORMAT_VERSIONS, or select a matching Xcode."; \
	    exit 1; \
	  fi; \
	  echo "Linting anyway. CI lints under $(SWIFT_FORMAT_VERSIONS) and may disagree."; \
	fi

swift-format-version:
	@$(call swift_format_guard,fail)

format-swift: ## Format the Swift half with swift-format
	@$(call swift_format_guard,fail)
	@xcrun swift-format format --in-place --recursive --parallel $(SWIFT_SRC)

# `--strict` is what makes this a gate: without it lint prints its findings and
# still exits 0, so CI would pass while reporting every violation it found.
format-swift-check: ## Fail on unformatted Swift
	@$(call swift_format_guard,warn)
	@xcrun swift-format lint --recursive --parallel --strict $(SWIFT_SRC)

# `git blame` walks straight into the reformat commit unless told not to, and the
# file that says so is per-clone config the repo cannot set for you. GitHub reads
# .git-blame-ignore-revs by itself; GitLab and your terminal do not.
blame-setup: ## Teach git blame to skip the formatting-only commits
	@git -C ../.. config blame.ignoreRevsFile .git-blame-ignore-revs
	@echo "git blame will skip the commits in .git-blame-ignore-revs"

# ── Unit checks ───────────────────────────────────────────────────────────────
#
# The app target has no test bundle, so the files that are pure functions of their
# input are compiled beside a check driver with `swiftc` and run: bastion's `make
# unit`, and the shape the root's `license-check` already uses for License.swift.
# No app, no network, no config folder, no port.
#
# Compiled with the app target's own language settings: Swift 6, main-actor default
# isolation, and the two approachable-concurrency features that change what compiles.
# A file that stops building alone under them fails here the way it would fail the
# app. Every file listed has to compile without the rest of the app; where one reached
# further, it was given a seam rather than more of the app on this line.
UNIT_BIN := $(DERIVED_DATA)/unit-check
UNIT_SRC := \
	Armada/JSONLines.swift \
	Armada/TranscriptTitle.swift \
	Armada/TranscriptContext.swift \
	Armada/TranscriptQuota.swift \
	Armada/UsageSnapshot.swift \
	Armada/UsageForecast.swift \
	Armada/DayWeights.swift \
	Armada/PaceProfile.swift \
	Armada/ContextWindow.swift \
	Armada/CodexContext.swift \
	Armada/CodexRollout.swift \
	Armada/SessionOrder.swift \
	Armada/Changelog.swift \
	Armada/HostWindow.swift \
	Armada/ProjectPath.swift \
	Armada/Project.swift \
	Armada/UsageLedger.swift \
	Armada/UsageLines.swift \
	Armada/UsageIngest.swift \
	Armada/ProjectStats.swift \
	Armada/LaunchScript.swift \
	Armada/ClaudeTrust.swift \
	Armada/License.swift \
	Armada/Revocations.swift \
	UnitChecks/AppInfoStub.swift \
	UnitChecks/UnitCheck.swift

unit: ## Check the parsers, forecasts, sort order and licence refusals, with no app and no network
	@mkdir -p $(DERIVED_DATA)
	@xcrun swiftc -swift-version 6 -default-isolation MainActor \
		-enable-upcoming-feature InferIsolatedConformances \
		-enable-upcoming-feature NonisolatedNonsendingByDefault \
		-o $(UNIT_BIN) $(UNIT_SRC)
	@$(UNIT_BIN)

.PHONY: unit
