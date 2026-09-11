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

XCARGS ?=
BUILD_ARGS = ARMADA_GIT_COMMIT=$(GIT_COMMIT) \
	$(if $(GIT_COUNT),CURRENT_PROJECT_VERSION=$(GIT_COUNT),) $(XCARGS)

APP_BUNDLE = $(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app

.DEFAULT_GOAL := help

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the app in Debug
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) $(BUILD_ARGS)

build-release: ## Build the app in Release
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) $(BUILD_ARGS)

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

# ── Icon ──────────────────────────────────────────────────────────────────────
#
# Owned by the appshot-app-icon skill; these only name the entry points. The source
# of truth is design/armada-mark.svg at the repo root, from which the Icon Composer
# bundle is regenerated.
ICON_SRC = ../../design/armada-mark.svg
ICON_OUT = Armada/Armada.icon

icon: ## Rebuild Armada.icon from design/armada-mark.svg
	@echo "Run the appshot-app-icon skill: $(ICON_SRC) -> $(ICON_OUT)"
	@exit 1

icon-check: ## Fail if the icon is stale against its source SVG
	@echo "Run the appshot-app-icon skill to verify $(ICON_OUT)"
	@exit 1

.PHONY: help build build-release run quit clean icon icon-check \
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
SWIFT_SRC := Armada

# swift-format's version follows whichever Xcode is selected, so a toolchain bump
# can reformat the whole tree with no change to `.swift-format` and turn the gate
# red on code nobody edited. Assert it, so that day arrives as a sentence rather
# than a mystery diff.
SWIFT_FORMAT_VERSION := 6.3

swift-format-version:
	@v="$$(xcrun swift-format --version)"; \
	case "$$v" in \
	  $(SWIFT_FORMAT_VERSION).*) ;; \
	  *) echo "swift-format $$v, expected $(SWIFT_FORMAT_VERSION).x — the toolchain moved."; \
	     echo "Reformat deliberately and bump SWIFT_FORMAT_VERSION, or select the matching Xcode."; \
	     exit 1;; \
	esac

format-swift: swift-format-version ## Format the Swift half with swift-format
	@xcrun swift-format format --in-place --recursive --parallel $(SWIFT_SRC)

# `--strict` is what makes this a gate: without it lint prints its findings and
# still exits 0, so CI would pass while reporting every violation it found.
format-swift-check: swift-format-version ## Fail on unformatted Swift
	@xcrun swift-format lint --recursive --parallel --strict $(SWIFT_SRC)

# `git blame` walks straight into the reformat commit unless told not to, and the
# file that says so is per-clone config the repo cannot set for you. GitHub reads
# .git-blame-ignore-revs by itself; GitLab and your terminal do not.
blame-setup: ## Teach git blame to skip the formatting-only commits
	@git -C ../.. config blame.ignoreRevsFile .git-blame-ignore-revs
	@echo "git blame will skip the commits in .git-blame-ignore-revs"
