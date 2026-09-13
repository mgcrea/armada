# One entrypoint at the repo root. This is not a build system: the whole build is `make` in
# apps/apple, and this file forwards to it so the commands are the same from either place.
#
# Why forwarding is safe: `make -C` chdirs *before reading the makefile* (man make: "Change
# to directory dir before reading the makefiles or doing anything else"), so every relative
# path in apps/apple/Makefile — .build/, Armada.xcodeproj, SWIFT_SRC — resolves exactly as
# it does when you cd there yourself. That matters more than it looks: xcodebuild has no
# notion of a project root and resolves every path against the process working directory.
#
# Command-line variables reach the sub-make through MAKEFLAGS, so
# `make build XCARGS='CODE_SIGNING_ALLOWED=NO'` works from here.

APPLE := apps/apple

# Read out of the sub-makefile's own `## ` help comments, so a target added there is
# forwardable from here without touching this file.
#
# Deliberately NOT copied from its .PHONY list: that list is maintained by hand and drifts.
# `help` is dropped because the root has its own.
APPLE_TARGETS := $(filter-out help,\
	$(shell sed -n 's/^\([a-zA-Z0-9_-]*\):.*##.*/\1/p' $(APPLE)/Makefile))

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@echo "  \033[1mroot\033[0m"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  \033[1mapps/apple\033[0m"
	@$(MAKE) -s -C $(APPLE) help
	@echo ""

$(APPLE_TARGETS):
	@$(MAKE) -C $(APPLE) $@

.PHONY: help $(APPLE_TARGETS)

# ── Icon ──────────────────────────────────────────────────────────────────────
#
# Root-level, because the pipeline spans both halves of the repo: the source is
# design/armada-mark.svg and the outputs are design/armada-icon.svg and the Icon
# Composer bundle inside apps/apple. A target in apps/apple/Makefile would have
# to reach up through ../.. for both.
#
# One mark, every rendering, one command. The mark and the three menu bar glyphs
# are the only geometry anybody edits; everything below is derived.

ICON_MARK   := design/armada-mark.svg
# `#` starts a comment in a makefile, so the hex colours are built from a variable.
HASH        := \#
ICON_PLATE   = $(HASH)FFD9A2,$(HASH)F6A177
ICON_RADIUS := 230
ICON_BUNDLE := apps/apple/Armada/Armada.icon
ASSETS      := apps/apple/Armada/Assets.xcassets

# The three menu bar glyphs are AUTHORED, never composed from the mark: their
# sizing is a menu-bar problem the 1024 mark knows nothing about, and the halo's
# geometry is fitted against cupertino's and bastion's glyphs rather than against
# this repo's own artwork. `make icon` only ever COPIES them into their imagesets,
# which is why those copies are listed as generated and these three are not.
#
# `actool` reads the SVGs directly and keeps the vector representation, so there
# are no PNG slots to keep in step.
ICON_MENUBAR := armada-menubar:MenuBarIcon \
	armada-menubar-active:MenuBarIconActive \
	armada-menubar-active-halo:MenuBarIconActiveHalo

icon: ## Rebuild Armada.icon and the web SVG from design/armada-mark.svg
	@# `--mark-fraction 1.0`: the mark is a scene that bleeds off all four edges,
	@# not a centred glyph, so it maps 1:1. The usual 70-80% band does not apply.
	@appshot icon build --from $(ICON_MARK) \
		--plate-gradient '$(ICON_PLATE)' --plate-angle 90 --mark-fraction 1.0 \
		--out $(ICON_BUNDLE)
	@appshot icon build --from $(ICON_MARK) \
		--plate-gradient '$(ICON_PLATE)' --plate-angle 90 --mark-fraction 1.0 \
		--corner-radius $(ICON_RADIUS) --label 'Armada' \
		--out design/armada-icon.svg
	@# The waves bleed past the plate's corner radius by design, and nothing masks
	@# an SVG on a web page — so the vector needs the clip the OS applies for free.
	@#
	@# `perl -0777`, so each substitution runs ONCE over the whole file rather than
	@# once per line. The mark carries its own <defs> for the waterline clip, so a
	@# line-by-line pass matches twice and writes a duplicate `id="c"`.
	@#
	@# perl rather than `sed -i`: the flag's in-place syntax differs between BSD and
	@# GNU sed, and Homebrew's gnu-sed shadows the system one on some of these Macs.
	@perl -0777 -pi \
		-e 's|</defs>|<clipPath id="c"><rect width="1024" height="1024" rx="$(ICON_RADIUS)"/></clipPath></defs>|;' \
		-e 's|<g transform=|<g clip-path="url($(HASH)c)" transform=|;' \
		design/armada-icon.svg
	@for pair in $(ICON_MENUBAR); do \
		svg="design/$${pair%%:*}.svg"; \
		dir="$(ASSETS)/$${pair##*:}.imageset"; \
		cp "$$svg" "$$dir/"; \
	done
	@appshot icon check --out $(ICON_BUNDLE)

icon-check: ## Fail if the icon is stale against its source SVG
	@# Two different questions, and the second is the one that catches drift.
	@# `appshot icon check` asserts the bundle is well formed — every slot present,
	@# no plate baked into the mark layer. It cannot tell whether the artwork still
	@# matches design/armada-mark.svg, so the mark is rebuilt into a scratch bundle
	@# and compared byte for byte.
	@appshot icon check --out $(ICON_BUNDLE)
	@tmp=$$(mktemp -d); \
	appshot icon build --from $(ICON_MARK) \
		--plate-gradient '$(ICON_PLATE)' --plate-angle 90 --mark-fraction 1.0 \
		--out "$$tmp/Armada.icon" >/dev/null; \
	if diff -r "$$tmp/Armada.icon" $(ICON_BUNDLE) >/dev/null 2>&1; then \
		rm -rf "$$tmp"; echo "  ok    $(ICON_BUNDLE) matches $(ICON_MARK)"; \
	else \
		echo "  FAIL  $(ICON_BUNDLE) is stale against $(ICON_MARK) — run \`make icon\`"; \
		diff -rq "$$tmp/Armada.icon" $(ICON_BUNDLE) || true; \
		rm -rf "$$tmp"; exit 1; \
	fi
	@# The imageset copies are the other half of `make icon`, and they drift
	@# silently: a hand-edited glyph in Assets.xcassets builds and ships.
	@for pair in $(ICON_MENUBAR); do \
		svg="design/$${pair%%:*}.svg"; \
		dir="$(ASSETS)/$${pair##*:}.imageset"; \
		if cmp -s "$$svg" "$$dir/$${pair%%:*}.svg"; then \
			echo "  ok    $$dir is a copy of $$svg"; \
		else \
			echo "  FAIL  $$dir has drifted from $$svg — run \`make icon\`"; \
			exit 1; \
		fi; \
	done

.PHONY: icon icon-check

# ── Audits ────────────────────────────────────────────────────────────────────
#
# Root-level because the script is, and because the claim is about the repo
# rather than about the Xcode project. Not in APPLE_TARGETS: that list is read
# out of apps/apple/Makefile's own `## ` comments, so a target defined here
# cannot collide with one defined there.

audit: build ## Assert the built app cannot reach the network
	@scripts/audit-network.sh

.PHONY: audit
