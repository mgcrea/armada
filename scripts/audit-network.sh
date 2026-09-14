#!/usr/bin/env bash
#
# Assert that nothing Armada ships can reach the network on its own, beyond the
# one thing that is allowed to and is named here.
#
# Armada reads every transcript on the machine — every conversation you have had
# with an agent, across every account. The claim that none of it leaves the Mac
# is the one worth checking rather than asserting, so this runs against the BUILT
# artifact: any user can point it at the .app they downloaded and get the answer
# CI got.
#
#   scripts/audit-network.sh [path/to/Armada.app]
#
# This file used to have no allowance table at all, and said that the day Armada
# grew an updater it would grow one and SECURITY.md would be reworded in the same
# commit. That day is this file: Sparkle is the one exception, allowed exactly the
# symbols it was measured to use, and the claim now says so.
#
# Cupertino's script is the model, and the Sparkle rules below are its rules.
# Bastion's cannot be — it binds a loopback socket on purpose and so cannot make
# the claim at all.
#
# What it does NOT assert, deliberately:
#
#   * `socket`, `bind`, `connect`. Armada opens no socket of its own, but those
#     syscalls are shared with local IPC, so they could never be the test.
#     AF_INET is the test, and it is asserted at the source level below.
#   * What the `claude` process Armada spawns then does. It talks to Anthropic —
#     that is its job, on the user's own sign-in. This audits Armada, not the
#     program it asks a question of. See SECURITY.md.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-apps/apple/.build/Build/Products/Debug/Armada.app}"
status=0
checked=0
saw_sparkle=0

# High-level networking only. Every one of these implies an intent no local path
# has: loading a URL, resolving a name, negotiating TLS.
DENY='URLSession|URLConnection|URLRequest|URLDownload|^_nw_|_CFHTTP|_CFURLRequest|CFReadStreamCreateForHTTP|_getaddrinfo|_gethostby|_res_9_|_SSLHandshake|_SSLCreateContext|_curl_'

# ---------------------------------------------------------------------------
# The exception, in one place. Adding a line here is the whole decision, and it
# is a diff a stranger can read.
# ---------------------------------------------------------------------------

# Sparkle is the update checker: the one thing in this bundle that opens a socket
# to the internet. It does so only once the user has turned checks on or pressed
# Check Now, and SECURITY.md carries the reworded claim that admits it.
SPARKLE_BIN='Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'

# And exactly which symbols it may have — measured against the pinned version by
# cupertino, not assumed. A Sparkle that starts resolving names itself, negotiates
# TLS by hand or links CFNetwork directly fails this line rather than inheriting
# the allowance the previous version earned.
SPARKLE_ALLOWED='^_OBJC_CLASS_\$_(NSURLSession|NSURLSessionConfiguration|NSMutableURLRequest)$'

# Set to 0 for a deliberately Sparkle-free build. Left at 1, a bundle that has
# lost Sparkle is a failure rather than a quiet pass — see the stale-allowance
# check below.
SPARKLE_EXPECTED="${SPARKLE_EXPECTED:-1}"

FEED_URL='https://armada.mgcrea.io/appcast.xml'

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

  if [ "$rel" = "$SPARKLE_BIN" ]; then
    saw_sparkle=1
    # The allowance is exact, not a blanket pardon for a path.
    unexpected=$(printf '%s\n' "$hits" | grep -v '^$' | grep -vE "$SPARKLE_ALLOWED" || true)
    if [ -n "$unexpected" ]; then
      printf '  FAIL  %-46s Sparkle grew a network capability it did not have:\n' "$rel"
      printf '%s\n' "$unexpected" | sed 's/^/          /'
      status=1
    else
      printf '  UPD   %-46s reaches the network — the update check, off by default\n' "$rel"
    fi
    continue
  fi

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

# A pardon that outlives the thing it pardons is a hole waiting for whatever
# lands at that path next. If Sparkle is ever dropped, the allowance has to be
# dropped with it, and the way to guarantee that is to fail until it is.
if [ "$SPARKLE_EXPECTED" = "1" ] && [ "$saw_sparkle" -eq 0 ]; then
  printf '  FAIL  %-46s the allowance names a binary this bundle does not contain\n' "$SPARKLE_BIN"
  status=1
fi

# ---------------------------------------------------------------------------
# The symbol sweep says the capability exists. These say it is switched off and
# points where we said it does — which is what turns "off by default" from a
# promise in a settings pane into something CI refuses to ship without.
# ---------------------------------------------------------------------------
if [ "$saw_sparkle" -eq 1 ]; then
  echo ""
  echo "  Configuration — the update check is off until asked for"
  plist="$APP/Contents/Info.plist"
  pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }

  assert_plist() {
    local key="$1" want="$2" got
    got=$(pb "$key")
    if [ "$got" = "$want" ]; then
      printf '  ok    %-46s %s\n' "$key" "$got"
    else
      printf '  FAIL  %-46s is %s, must be %s\n' "$key" "${got:-absent}" "$want"
      status=1
    fi
  }

  # Absent is not the same as false: an ABSENT SUEnableAutomaticChecks is exactly
  # what makes Sparkle ask on its own, in its own words, which is the outcome the
  # consent card was written to replace.
  assert_plist SUEnableAutomaticChecks false
  assert_plist SUAutomaticallyUpdate false
  assert_plist SUSendProfileInfo false
  assert_plist SUFeedURL "$FEED_URL"

  # Present is not enough. An ed25519 public key is 32 bytes in base64 — 44
  # characters ending in '=' — so a build that never had a real key wired in
  # fails here rather than shipping an updater that trusts nobody's signature.
  edkey=$(pb SUPublicEDKey)
  if printf '%s' "$edkey" | grep -qE '^[A-Za-z0-9+/]{43}=$'; then
    printf '  ok    %-46s well-formed\n' "SUPublicEDKey"
  elif [ -z "$edkey" ]; then
    printf '  FAIL  %-46s absent — updates would be unverified\n' "SUPublicEDKey"
    status=1
  else
    printf '  FAIL  %-46s not an ed25519 public key: %s\n' "SUPublicEDKey" "$edkey"
    status=1
  fi

  # Sandbox-only, and this app is not sandboxed. Stripped by `make sparkle`
  # because each one is another binary that would need pardoning here.
  if [ -d "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" ]; then
    printf '  FAIL  %-46s sandbox-only XPC services ship\n' "XPCServices"
    status=1
  else
    printf '  ok    %-46s stripped\n' "XPCServices"
  fi
fi

# The binary sweep cannot rule out a raw socket, because those syscalls are
# shared with local IPC. This can, for the code we wrote: a socket that never
# names an internet address family is not one.
echo ""
echo "  Sources — an internet address family appears nowhere"
SOURCES=(apps/apple/Armada)
# Vendor/ is not our source. Sparkle's own test harness contains a `sockaddr_in`
# web server; what constrains the framework is the symbol sweep above.
PRUNE=(--exclude-dir=.build --exclude-dir=Vendor)
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

# And the signature agrees, for a bundle that carries a real one. The project
# check above is about the sources; this is about the artifact a user runs.
#
# Skipped, loudly, for the two kinds of signature that cannot carry entitlements
# anyway. CODE_SIGNING_ALLOWED=NO does not produce an UNSIGNED binary on Apple
# silicon, it produces an ad-hoc linker-signed one — cupertino learned that when
# its version of this read came back empty and, under `set -e` with `pipefail`,
# killed the script mid-audit with no message. A security audit that dies
# silently is worse than one that fails loudly.
#
# get-task-allow is tolerated because a Debug build carries it and a notarized
# one cannot: notarization refuses it.
siginfo=$(codesign -dv "$APP" 2>&1 || true)
case "$siginfo" in
  *"not signed at all"*) skip="unsigned build" ;;
  *adhoc* | *linker-signed*) skip="ad-hoc signed build" ;;
  *) skip="" ;;
esac
if [ -n "$skip" ]; then
  printf '  --    %-46s %s, not checked\n' "signed entitlements" "$skip"
else
  granted=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null |
    plutil -convert json -o - - 2>/dev/null |
    python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null ||
    true)
  case "$granted" in
    "" | "com.apple.security.get-task-allow")
      printf '  ok    %-46s none\n' "signed entitlements" ;;
    *)
      printf '  FAIL  %-46s unexpected: %s\n' "signed entitlements" "$granted"
      status=1 ;;
  esac
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
  if [ "$saw_sparkle" -eq 1 ]; then
    echo "  Armada opens exactly one connection of its own: the update check, to"
    echo "  armada.mgcrea.io, and only once you turn it on. Nothing it reads leaves this Mac."
  else
    echo "  Armada opens no socket of its own. Nothing it reads leaves this Mac."
  fi
  echo "  This says nothing about the \`claude\` it spawns, which talks to Anthropic"
  echo "  on your own sign-in — see SECURITY.md."
else
  echo "  Audit failed — see SECURITY.md for what this claim is load-bearing for."
fi
echo ""
exit "$status"
