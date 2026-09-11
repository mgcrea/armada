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
