#!/usr/bin/env bash
#
# Assert that nothing Armada ships can reach the network.
#
# Armada reads every transcript on the machine — every conversation you have had
# with an agent, across every account. The claim that none of it leaves the Mac
# is the one worth checking rather than asserting, so this runs against the BUILT
# artifact: any user can point it at the .app they have and get the answer CI got.
#
#   scripts/audit-network.sh [path/to/Armada.app]
#
# This is cupertino's `audit-network.sh`, kept and simplified rather than copied
# wholesale. Cupertino has to pardon Sparkle and an embedded node; bastion cannot
# make the claim at all, because it binds a loopback socket on purpose. Armada
# has no updater, no runtime and no listener, so the allowance table those two
# need is deliberately absent here: ANY hit is a failure. If Armada ever grows an
# updater, this file grows an exceptions table and the claim in SECURITY.md gets
# reworded — in the same commit.
#
# What it does NOT assert, deliberately:
#
#   * `socket`, `bind`, `connect`. Armada opens no socket of any kind today, but
#     those syscalls are shared with local IPC, so they could never be the test.
#     AF_INET is the test, and it is asserted at the source level below.
#   * What the `claude` process Armada spawns then does. It talks to Anthropic —
#     that is its job, on the user's own sign-in. This audits Armada, not the
#     program it asks a question of. See SECURITY.md.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-apps/apple/.build/Build/Products/Debug/Armada.app}"
status=0
checked=0

# High-level networking only. Every one of these implies an intent no local path
# has: loading a URL, resolving a name, negotiating TLS.
DENY='URLSession|URLConnection|URLRequest|URLDownload|^_nw_|_CFHTTP|_CFURLRequest|CFReadStreamCreateForHTTP|_getaddrinfo|_gethostby|_res_9_|_SSLHandshake|_SSLCreateContext|_curl_'

# Every Mach-O in the bundle, FOUND rather than listed: a framework or helper
# that nobody remembered to add to a hand-written list is precisely what this
# gate exists to catch.
mach_o_paths() {
  find "$APP/Contents" -type f -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      case "$(file -b "$f" 2>/dev/null)" in
        *Mach-O*) printf '%s\n' "${f#"$APP/"}" ;;
      esac
    done | LC_ALL=C sort
}

# sort -u because nm lists undefined symbols once per architecture slice, and a
# universal binary would otherwise report every hit twice.
scan() {
  {
    nm -u "$1" 2>/dev/null | grep -E "$DENY" || true
    otool -L "$1" 2>/dev/null | grep -E 'CFNetwork|/Network\.framework' || true
  } | sed 's/^[[:space:]]*//' | grep -v '^$' | sort -u || true
}

if [ ! -d "$APP" ]; then
  echo ""
  echo "  FAIL  no bundle at $APP — run \`make build\` first"
  echo ""
  exit 1
fi

echo ""
echo "  Binaries — $APP"

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  checked=$((checked + 1))
  hits=$(scan "$APP/$rel")
  if [ -n "$hits" ]; then
    count=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
    printf '  FAIL  %-46s reaches the network (%s symbols):\n' "$rel" "$count"
    printf '%s\n' "$hits" | head -8 | sed 's/^/          /'
    [ "$count" -gt 8 ] && printf '          … and %s more\n' "$((count - 8))"
    status=1
  else
    printf '  ok    %-46s no URL loading, no DNS, no TLS\n' "$rel"
  fi
done <<EOF
$(mach_o_paths)
EOF

# The binary sweep cannot rule out a raw socket, because those syscalls are
# shared with local IPC. This can, for the code we wrote: a socket that never
# names an internet address family is not one.
echo ""
echo "  Sources — an internet address family appears nowhere"
SOURCES=(apps/apple/Armada)
PRUNE=(--exclude-dir=.build)
for dir in "${SOURCES[@]}"; do
  # `grep -r` over a directory that has been moved away returns nothing and exits
  # non-zero, which `|| true` would launder into a pass — so existence is checked
  # rather than assumed. The check would otherwise report "ok" having read no
  # source at all.
  [ -d "$dir" ] || {
    printf '  FAIL  %-46s no such directory: %s\n' "sources" "$dir"
    status=1
  }
done
inet=$(grep -rInE "${PRUNE[@]}" 'AF_INET|PF_INET|sockaddr_in\b|sockaddr_in6' "${SOURCES[@]}" 2>/dev/null || true)
if [ -n "$inet" ]; then
  printf '  FAIL  %s\n' "an internet address family is referenced:"
  printf '%s\n' "$inet" | sed 's/^/          /'
  status=1
else
  printf '  ok    %-46s no internet address family\n' "sockets"
fi

# Armada ships no entitlements file at all, and that is a property rather than an
# oversight: nothing it does needs one. An EMPTY permission set that is true by
# construction is checkable; one arrived at by deletion is not — so this asserts
# the setting is ABSENT from the project rather than present and empty.
echo ""
echo "  Entitlements — none, by construction"
if grep -q 'CODE_SIGN_ENTITLEMENTS' apps/apple/Armada.xcodeproj/project.pbxproj; then
  printf '  FAIL  %-46s the project names an entitlements file\n' "CODE_SIGN_ENTITLEMENTS"
  status=1
else
  printf '  ok    %-46s the project names none\n' "CODE_SIGN_ENTITLEMENTS"
fi

# A gate that passes when it inspected nothing is not a gate. No binary found
# means the build did not happen, and that is a failure rather than a quiet pass.
if [ "$checked" -eq 0 ]; then
  echo ""
  echo "  FAIL  audited nothing — no Mach-O binary found under $APP"
  status=1
fi

echo ""
if [ "$status" -eq 0 ]; then
  echo "  Audited $checked Mach-O file(s)."
  echo "  Armada opens no socket of its own. Nothing it reads leaves this Mac."
  echo "  This says nothing about the \`claude\` it spawns, which talks to Anthropic"
  echo "  on your own sign-in — see SECURITY.md."
else
  echo "  Audit failed — see SECURITY.md for what this claim is load-bearing for."
fi
echo ""
exit "$status"
