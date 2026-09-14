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
#
# The `##` is spelled through a variable, not written inline. GNU make 3.81 — the
# /usr/bin/make on macOS, and so on every CI runner — reads a literal `#` inside a
# `$(shell ...)` in an assignment as the start of a comment, and aborts with
# "unterminated call to function `filter-out'". The Homebrew make 4.x on a
# developer's PATH does not, which is how this passed locally and failed the first
# push CI ever saw.
HASH := \#
APPLE_TARGETS := $(filter-out help,\
	$(shell sed -n 's/^\([a-zA-Z0-9_-]*\):.*$(HASH)$(HASH).*/\1/p' $(APPLE)/Makefile))

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

audit: build ## Assert the built Debug app cannot reach the network
	@scripts/audit-network.sh

# The same script against the artifact that ships. No `build` prerequisite on
# purpose: rebuilding here would replace the signed, stapled bundle it exists to
# inspect with an unsigned one.
audit-release: ## Assert the signed Release app cannot reach the network
	@SPARKLE_EXPECTED=1 scripts/audit-network.sh "$(RELEASE_APP)"

.PHONY: audit audit-release

# ── Changelog ─────────────────────────────────────────────────────────────────
#
# CHANGELOG.md → Changelog.swift, the What's New pane's data. Root-level for the
# same reason as the icon: the source is at the root, the output is in apps/apple.
# `changelog-check` is the CI gate — a stale Changelog.swift fails there rather
# than shipping notes that describe a different build.

changelog: ## Regenerate Changelog.swift from CHANGELOG.md
	@node scripts/generate-changelog.mjs

changelog-check: ## Fail if Changelog.swift is stale against CHANGELOG.md
	@node scripts/generate-changelog.mjs --check

.PHONY: changelog changelog-check

# ── Release ───────────────────────────────────────────────────────────────────
#
# The direct-distribution path bastion and cupertino share: an unsigned Release
# build, signed inside out, notarized, stapled, re-zipped, and a one-item Sparkle
# appcast signed over the stapled zip. Root-level for the icon's and the
# changelog's reason — it reads CHANGELOG.md and scripts/ here and writes into
# apps/apple/.build — so apps/apple/Makefile only ever builds.
#
# There is no bump or release script, in this repo or either sibling. A release
# is a commit, a signed `app-v<version>` tag, and the release-app job in
# .github/workflows/ci.yml, which runs build-release, verifies the artifact, then
# runs appcast. `make build-release` locally is a rehearsal, never how one ships.

TEAM_ID     := 75QE9PRT3V
RELEASE_DIR := apps/apple/.build
RELEASE_APP ?= $(RELEASE_DIR)/Build/Products/Release/Armada.app
# Deferred, so it follows RELEASE_APP if a caller overrides that.
RELEASE_SPARKLE = $(RELEASE_APP)/Contents/Frameworks/Sparkle.framework
RELEASE_ZIP := $(RELEASE_DIR)/Armada.zip
APPCAST     := $(RELEASE_DIR)/appcast.xml
SPARKLE_TOOLS := apps/apple/Vendor/bin
INSTALLED   := /Applications/Armada.app

# Signing is switched OFF for the build and done by `sign` alone. Xcode's own
# signing step would sign with whatever Automatic resolves to, in whatever order
# it likes; the release has to be one identity, one order, and assertions after.
bundle: ## Build an unsigned Release Armada.app, then sign it
	@$(MAKE) --no-print-directory -C apps/apple build CONFIG=Release \
		XCARGS="$(XCARGS) CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"
	@$(MAKE) --no-print-directory sign

# Inside out: Sparkle's Updater.app, then Autoupdate, then the framework, then the
# app. A signature over a bundle is a signature over its contents, so anything
# signed after the wrapper invalidates it.
#
# Never `--deep`. It re-signs nested code with the OUTER identity and options and
# drops nested designated requirements; Apple documents it as unsuitable for
# signing. `codesign --verify --deep` below is a different verb.
#
# No `--entitlements` on the app, and that is the claim rather than an omission:
# nothing Armada does needs one. `make audit` asserts the project names no
# entitlements file, and the check below asserts none ended up on the signature.
#
# The identity block is ONE shell invocation because `$$id` has to survive across
# the codesign calls.
sign: ## Sign the Release bundle inside out (Developer ID if present, else Apple Development)
	@test -d "$(RELEASE_APP)" || { echo "  no $(RELEASE_APP) — run 'make bundle'" >&2; exit 1; }
	@test -d "$(RELEASE_SPARKLE)" || { echo "  no Sparkle.framework in $(RELEASE_APP) — the updater is missing" >&2; exit 1; }
	@id=$$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $$2; exit}'); \
	if [ -z "$$id" ]; then \
		id=$$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $$2; exit}'); \
		echo "  !! no Developer ID Application certificate — signing with Apple Development."; \
		echo "     This build will NOT notarize and will not run on another Mac."; \
	fi; \
	test -n "$$id" || { echo "  no codesigning identity at all" >&2; exit 1; }; \
	codesign --force --options runtime --timestamp --sign "$$id" \
		"$(RELEASE_SPARKLE)/Versions/B/Updater.app" && \
	codesign --force --options runtime --timestamp --sign "$$id" \
		"$(RELEASE_SPARKLE)/Versions/B/Autoupdate" && \
	codesign --force --options runtime --timestamp --sign "$$id" \
		"$(RELEASE_SPARKLE)" && \
	codesign --force --options runtime --timestamp --sign "$$id" "$(RELEASE_APP)"
	@codesign --verify --deep --strict --verbose=1 "$(RELEASE_APP)"
	@codesign -d --entitlements - --xml "$(RELEASE_APP)" 2>/dev/null | grep -q '<key>' \
		&& { echo "  the app carries entitlements — it should carry none" >&2; exit 1; } \
		|| echo "  no entitlements on the app"
	@# The hardened runtime is on and nothing disables library validation, so a
	@# Sparkle signed by another team fails at dlopen — at launch, on a user's Mac,
	@# long after this. Assert the team here, where the message is readable.
	@codesign -dv --verbose=2 "$(RELEASE_SPARKLE)" 2>&1 | grep -q 'TeamIdentifier=$(TEAM_ID)' \
		|| { echo "  Sparkle is not signed by $(TEAM_ID) — library validation will reject it" >&2; exit 1; }
	@echo "  Sparkle signed by $(TEAM_ID)"
	@# DIVERGES from bastion, which only warns: a bundle whose public key is not a
	@# real one can verify no appcast, so it can never be updated, and the only
	@# moment anyone would notice is the release that needed to ship.
	@/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$(RELEASE_APP)/Contents/Info.plist" 2>/dev/null \
		| grep -qE '^[A-Za-z0-9+/]{43}=$$' \
		|| { echo "  SUPublicEDKey is not an ed25519 public key — this build could never be updated" >&2; exit 1; }
	@echo "  size: $$(du -sh "$(RELEASE_APP)" | cut -f1)"

notarize: ## Submit the signed bundle to Apple and staple the ticket
	@# All three, not just the first: bastion's guard once checked only AC_KEY_ID,
	@# and notarytool then failed on an empty --key after a minute of zipping.
	@for v in AC_KEY_ID AC_ISSUER_ID AC_KEY_PATH; do \
		eval "value=\$$$$v"; \
		[ -n "$$value" ] || { echo "set AC_KEY_ID, AC_ISSUER_ID and AC_KEY_PATH first ($$v is empty)" >&2; exit 1; }; \
	done
	@ditto -c -k --keepParent "$(RELEASE_APP)" "$(RELEASE_ZIP)"
	@xcrun notarytool submit "$(RELEASE_ZIP)" --wait \
		--key "$$AC_KEY_PATH" --key-id "$$AC_KEY_ID" --issuer "$$AC_ISSUER_ID"
	@xcrun stapler staple "$(RELEASE_APP)"
	@# Re-zipped AFTER stapling: the ticket is written into the bundle, so the
	@# archive made before it carries none, and Gatekeeper on a Mac that is offline
	@# would reject it. Shipping the first zip is the classic mistake here.
	@ditto -c -k --keepParent "$(RELEASE_APP)" "$(RELEASE_ZIP)"
	@echo "  stapled: $(RELEASE_ZIP)"

# Sequential sub-makes rather than `build-release: bundle notarize`, because
# prerequisites may run in parallel under -j and notarizing a bundle that is still
# being signed staples a ticket to a cdhash that is about to change.
build-release: ## Build, sign and notarize a shippable Armada.app
	@$(MAKE) --no-print-directory bundle
	@$(MAKE) --no-print-directory notarize

# One item, never a history: Sparkle only needs the newest, and a feed that
# accumulates releases has to stay consistent with every zip still hosted.
#
# A RELEASE ASSET, not a site asset, with the enclosure at the tag's own upload.
# Publishing a release then never needs a site deploy, which is why /appcast.xml
# in apps/website/public/_redirects can be a permanent 302 — and SUFeedURL is baked
# into every binary ever shipped, so it has to outlive any decision about where
# files live.
#
# Signed over the STAPLED zip, which is why this is not folded into `notarize`: a
# signature made earlier is valid over an archive with no ticket, so Sparkle would
# accept the download and Gatekeeper would refuse it on first launch.
#
# The guards are the union of the siblings': cupertino's `set -e` with a trap that
# removes the key file on every exit path and its version-selected notes, which
# exit non-zero on a missing or empty section; bastion's enclosure length and its
# hard stop on an empty edSignature, the failure that otherwise ships a
# well-formed feed every installed updater refuses, forever. The length is `wc -c`
# rather than `stat`, whose flags differ between BSD and the GNU coreutils this
# Mac puts first on PATH.
appcast: ## Sign the stapled zip and write a one-item appcast
	@test -f "$(RELEASE_ZIP)" || { echo "no $(RELEASE_ZIP) — run 'make build-release' first" >&2; exit 1; }
	@$(MAKE) --no-print-directory -C apps/apple sparkle
	@set -e; \
	trap 'rm -f $(RELEASE_DIR)/sparkle.key' EXIT INT TERM; \
	if [ -n "$$SPARKLE_ED_PRIVATE_KEY" ]; then \
		: "# CI. The key reaches sign_update through a file, never argv: a private"; \
		: "# key on a command line is readable by every other process via ps."; \
		umask 077; printf '%s' "$$SPARKLE_ED_PRIVATE_KEY" > $(RELEASE_DIR)/sparkle.key; \
		raw=$$($(SPARKLE_TOOLS)/sign_update --ed-key-file $(RELEASE_DIR)/sparkle.key "$(RELEASE_ZIP)"); \
		rm -f $(RELEASE_DIR)/sparkle.key; \
	else \
		: "# A developer's Mac, where generate_keys keeps the key in the keychain."; \
		raw=$$($(SPARKLE_TOOLS)/sign_update "$(RELEASE_ZIP)"); \
	fi; \
	signature=$$(printf '%s' "$$raw" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/'); \
	test -n "$$signature" && [ "$$signature" != "$$raw" ] \
		|| { echo "  !! sign_update produced no edSignature; not shipping a feed" >&2; exit 1; }; \
	version=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(RELEASE_APP)/Contents/Info.plist"); \
	build=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(RELEASE_APP)/Contents/Info.plist"); \
	length=$$(wc -c < "$(RELEASE_ZIP)" | tr -d ' '); \
	notes=$$(node scripts/changelog-notes.mjs "$$version" CHANGELOG.md); \
	printf '%s\n' \
		'<?xml version="1.0" encoding="utf-8"?>' \
		'<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
		'  <channel>' \
		'    <title>Armada</title>' \
		'    <link>https://armada.mgcrea.io/appcast.xml</link>' \
		'    <item>' \
		"      <title>Armada $$version</title>" \
		"      <pubDate>$$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>" \
		"      <sparkle:version>$$build</sparkle:version>" \
		"      <sparkle:shortVersionString>$$version</sparkle:shortVersionString>" \
		'      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>' \
		"      <description><![CDATA[$$notes]]></description>" \
		"      <enclosure url=\"https://github.com/mgcrea/armada/releases/download/app-v$$version/Armada.zip\"" \
		"                 length=\"$$length\"" \
		'                 type="application/octet-stream"' \
		"                 sparkle:edSignature=\"$$signature\" />" \
		'    </item>' \
		'  </channel>' \
		'</rss>' > "$(APPCAST)"
	@xmllint --noout "$(APPCAST)" \
		|| { echo "  !! appcast.xml is not well-formed; not shipping it" >&2; rm -f "$(APPCAST)"; exit 1; }
	@echo "  appcast: $(APPCAST)"

# Deliberately NOT dependent on `bundle`: re-signing would invalidate the stapled
# ticket this exists to install.
install-release: ## Install the notarized Release build into /Applications
	@test -d "$(RELEASE_APP)" || { echo "no $(RELEASE_APP) — run 'make build-release' first" >&2; exit 1; }
	@xcrun stapler validate "$(RELEASE_APP)" >/dev/null 2>&1 \
		|| { echo "$(RELEASE_APP) carries no stapled ticket — run 'make build-release'" >&2; exit 1; }
	@if [ -d "$(INSTALLED)" ]; then \
		id=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(INSTALLED)/Contents/Info.plist" 2>/dev/null); \
		case "$$id" in \
			io.mgcrea.armada|io.mgcrea.armada.debug) ;; \
			*) echo "refusing to replace $(INSTALLED): its identifier is '$$id'" >&2; exit 1 ;; \
		esac; \
	fi
	-@osascript -e 'tell application id "io.mgcrea.armada" to quit' 2>/dev/null
	@sleep 1
	@rm -rf "$(INSTALLED)"
	@ditto "$(RELEASE_APP)" "$(INSTALLED)"
	@spctl -a -t exec "$(INSTALLED)" >/dev/null 2>&1 \
		&& echo "  installed $(INSTALLED) — Gatekeeper accepts it" \
		|| echo "  installed $(INSTALLED) — NOT accepted by Gatekeeper; it will not run on another Mac"

# Sparkle stores ONE signing key per user account, not one per app: a single item
# under https://sparkle-project.org in the login keychain. Bastion and cupertino
# already made and share it, and armada ships the same public key — decided again
# for this app on 2026-09-14 rather than inherited. One leaked key can therefore
# push an update to all three.
#
# That private key is the most dangerous secret this project has: together with
# the Developer ID certificate it is enough to hand every user a new version of an
# app that reads every agent transcript on their Mac. It belongs in the keychain
# and in one repository secret, never in an org-wide one and never anywhere a
# pull_request workflow can read it.
sparkle-keys: ## Print the shared EdDSA public key, and how to export the private one for CI
	@$(MAKE) --no-print-directory -C apps/apple sparkle
	@security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1 \
		|| { echo "  no Sparkle key in this login keychain — generating one would NOT match the siblings'" >&2; exit 1; }
	@echo "  public key (must equal SUPublicEDKey in apps/apple/Armada-Info.plist):"
	@$(SPARKLE_TOOLS)/generate_keys -p
	@echo ""
	@echo "  To give CI the private key:"
	@echo "    $(SPARKLE_TOOLS)/generate_keys -x sparkle_key.pem   # -x EXPORTS; without it you get a NEW key"
	@echo "    gh secret set SPARKLE_ED_PRIVATE_KEY -R mgcrea/armada < sparkle_key.pem"
	@echo "    make sparkle-key-shred"

# Not `rm -P`: that flag is BSD-only, and a Mac with Homebrew's coreutils ahead of
# /bin on PATH gets GNU rm, which errors on it — leaving the private key in the
# working tree after the one command whose whole job was to remove it. Overwrite
# first, then unlink by absolute path. Cupertino's target, copied.
sparkle-key-shred: ## Overwrite and remove an exported sparkle_key.pem
	@if [ ! -f sparkle_key.pem ]; then \
		echo "  no sparkle_key.pem here — nothing to shred"; \
	else \
		dd if=/dev/urandom of=sparkle_key.pem bs=$$(wc -c < sparkle_key.pem) count=1 \
			conv=notrunc 2>/dev/null; \
		/bin/rm -f sparkle_key.pem; \
		echo "  sparkle_key.pem overwritten and removed — the keychain copy is untouched"; \
	fi

.PHONY: bundle sign notarize build-release appcast install-release sparkle-keys sparkle-key-shred

# ── Licence ───────────────────────────────────────────────────────────────────
#
# The other half of the money loop. A refund or a lost chargeback marks the row in
# the Worker's D1; nothing reaches the app until this bakes the list into the next
# build, because the app is not allowed to ask anyone anything at runtime.
revocations: ## Rewrite the baked-in revocation list from the Worker's D1
	@node scripts/generate-revocations.mjs

# JavaScript mints the keys and Swift accepts them, so the disagreement that would
# cost money lives between the two — and neither side's own tests can see it. This
# compiles the real License.swift and feeds it keys signed with the real private
# key from .env, which is also what proves that key matches the public one
# compiled in.
license-check: ## Prove a minted licence key verifies in the app's own verifier
	@mkdir -p apps/apple/.build
	@swiftc -O -o apps/apple/.build/license-check \
		apps/apple/Armada/License.swift apps/apple/Armada/Revocations.swift \
		scripts/license-check.swift
	@node --env-file-if-exists=.env scripts/license-check.mjs \
		| apps/apple/.build/license-check

.PHONY: revocations license-check

# ── Website ───────────────────────────────────────────────────────────────────
#
# `pnpm run release`, spelled out: `deploy` is a pnpm builtin that exits 0 and
# ships nothing, which is why the package script is called `release` fleet-wide —
# and `run` makes the call a script even if pnpm ever grows a `release` of its own.
# The curl is the part that proves a deploy happened rather than that a command
# returned.
site-deploy: ## Build and deploy armada.mgcrea.io, then check it answers
	@pnpm -C apps/website run release
	@curl -fsS -o /dev/null https://armada.mgcrea.io && echo "  armada.mgcrea.io answers"

.PHONY: site-deploy

# ── API ───────────────────────────────────────────────────────────────────────
#
# The licence Worker at api.armada.mgcrea.io: Stripe's webhook in, a signed key
# out by email and on /thanks. Bastion's target, copied with its one hard lesson.

API_URL := https://api.armada.mgcrea.io/health

# Wrangler's d1 subcommands do not take `account_id` from wrangler.jsonc the way
# `deploy` does, and the token reaches three accounts, so without an explicit one
# they stop to ask — which inside a recipe is just a failure. The same value as
# wrangler.jsonc, which already documents it as public.
CF_ACCOUNT_ID := 0121e8859874c6fc0d674676e17d9f18

api-deploy: ## Build and publish the licence Worker, refusing on unapplied migrations
	@# Code expecting a table the database has not got deploys green and then fails
	@# on the first webhook: bastion's Worker spent four days answering 500 to
	@# every checkout that way, while the /health check below stayed 200. This
	@# refuses rather than applies; `pnpm -C apps/api migrate` stays deliberate.
	@CLOUDFLARE_ACCOUNT_ID=$(CF_ACCOUNT_ID) pnpm -C apps/api exec wrangler d1 migrations list armada-licenses --remote 2>&1 \
		| grep -q 'No migrations to apply' \
		|| { echo 'refusing to deploy: unapplied migrations in apps/api - run: pnpm -C apps/api migrate'; exit 1; }
	@pnpm -C apps/api run release
	@# A green `wrangler deploy` does not prove the Worker answers. This does.
	@curl -fsS --max-time 20 -o /dev/null $(API_URL)
	@echo "  deployed $(API_URL)"

# Sequential sub-makes rather than prerequisites: under -j they may run in
# parallel, and the Worker the site's /buy flow lands on has to be live first.
deploy: ## Deploy both halves: the licence Worker, then the website
	@$(MAKE) --no-print-directory api-deploy
	@$(MAKE) --no-print-directory site-deploy

.PHONY: api-deploy deploy
