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
# The second allowance is the supervisor's MCP endpoint, and it is a listening
# socket rather than a connection: swift-mcp-kit's loopback listener, never
# constructed until Settings ▸ Supervisor switches it on, bound to 127.0.0.1 and
# nothing else. It uses the POSIX socket calls, which the symbol sweep cannot deny
# because local IPC shares them, so its allowance is asserted where the socket is
# made instead: see "Loopback" below.
#
# The third allowance is not a network capability at all. It is here because this
# script is also where "no entitlements" used to be asserted: voice needs the
# microphone, and the hardened runtime grants it only through
# `com.apple.security.device.audio-input`. That one key is allowed, in the project
# and in the signature, and any other still fails. What voice sends goes through
# the `claude` Armada runs, which the list below already puts outside this audit.
#
# Cupertino's script is the model, and the Sparkle rules below are its rules.
# Bastion's cannot be — its loopback gateway is always on and is the product, where
# Armada's one listener is opt-in and read-only — so it cannot make the claim at all.
#
# What it does NOT assert, deliberately:
#
#   * `socket`, `bind`, `connect`. Those syscalls are shared with local IPC, so they
#     could never be the test. The address family is: none in Armada's own
#     sources, and in swift-mcp-kit's listener only the loopback address. Both are
#     asserted at the source level below.
#   * What the `claude` processes Armada spawns then do: the one it asks for plan
#     limits, and the one that answers voice questions. They talk to Anthropic —
#     that is their job, on the user's own sign-in. This audits Armada, not the
#     program it runs. See SECURITY.md.
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
SOURCES=(apps/apple/Armada apps/apple/Packages)
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

# ---------------------------------------------------------------------------
# The second allowance: the supervisor's MCP endpoint. The sweep above covers
# Armada's own sources, and the one internet socket in the bundle is not in them —
# it is swift-mcp-kit's loopback listener, linked in through Packages/ArmadaMCP. So
# the pardon is checked where the socket is made: the checkout the bundle was built
# from must bind the loopback literal it was measured to use, and must never name a
# wildcard or IPv6 address. Comment lines are skipped, because the kit's own
# documentation explains why 0.0.0.0 is refused, and grep cannot tell prose from code.
#
# A missing checkout is a failure rather than a skip. An allowance that could not be
# inspected has not been checked, and "ok" would say it had.
# ---------------------------------------------------------------------------
echo ""
echo "  Loopback — the MCP endpoint binds 127.0.0.1 and nothing else"
KIT_LISTENER=apps/apple/.build/SourcePackages/checkouts/swift-mcp-kit/Sources/MCPKitLoopback
KIT_VERSION=$(grep -A6 '"identity" : "swift-mcp-kit"' \
  apps/apple/Armada.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null |
  sed -n 's/.*"version" : "\(.*\)".*/\1/p' || true)
if [ ! -d "$KIT_LISTENER" ]; then
  printf '  FAIL  %-46s no checkout at %s — run `make build` first\n' "MCPKitLoopback" "$KIT_LISTENER"
  status=1
else
  code=$(grep -rnE --include='*.swift' 'AF_INET|INADDR_|0\.0\.0\.0|in6addr|s_addr' "$KIT_LISTENER" |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  wildcard=$(printf '%s\n' "$code" | grep -E 'INADDR_ANY|0\.0\.0\.0|in6addr|AF_INET6' || true)
  elsewhere=$(printf '%s\n' "$code" | grep 's_addr' | grep -v '0x7F00_0001' || true)
  loopback=$(printf '%s\n' "$code" | grep -c '0x7F00_0001' || true)
  if [ -n "$wildcard" ] || [ -n "$elsewhere" ]; then
    printf '  FAIL  %-46s binds something other than loopback:\n' "MCPKitLoopback"
    printf '%s\n%s\n' "$wildcard" "$elsewhere" | grep -v '^$' | sed 's/^/          /'
    status=1
  elif [ "$loopback" -lt 1 ]; then
    printf '  FAIL  %-46s no longer names the loopback literal it was measured to bind\n' "MCPKitLoopback"
    status=1
  else
    printf '  ok    %-46s binds 127.0.0.1 only (swift-mcp-kit %s)\n' "MCPKitLoopback" "${KIT_VERSION:-unpinned}"
  fi
fi

# Armada's one entitlement is the microphone, for voice. The project must name
# exactly `Armada.entitlements` in every configuration, and that file must grant
# exactly `com.apple.security.device.audio-input`: a permission set checked key by
# key, rather than one that merely happens to be small today.
echo ""
echo "  Entitlements — the microphone, and nothing else"
ENTITLEMENTS=apps/apple/Armada.entitlements
named=$(grep -o 'CODE_SIGN_ENTITLEMENTS = [^;]*;' apps/apple/Armada.xcodeproj/project.pbxproj | sort -u || true)
if [ "$named" = "CODE_SIGN_ENTITLEMENTS = Armada.entitlements;" ]; then
  printf '  ok    %-46s Armada.entitlements\n' "CODE_SIGN_ENTITLEMENTS"
else
  printf '  FAIL  %-46s expected Armada.entitlements, found: %s\n' "CODE_SIGN_ENTITLEMENTS" "${named:-none}"
  status=1
fi
declared=$(plutil -convert json -o - "$ENTITLEMENTS" 2>/dev/null |
  python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null ||
  true)
if [ "$declared" = "com.apple.security.device.audio-input" ]; then
  printf '  ok    %-46s audio-input only\n' "$ENTITLEMENTS"
else
  printf '  FAIL  %-46s expected audio-input only, found: %s\n' "$ENTITLEMENTS" "${declared:-nothing}"
  status=1
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
    "com.apple.security.device.audio-input" | \
      "com.apple.security.device.audio-input,com.apple.security.get-task-allow")
      printf '  ok    %-46s audio-input only\n' "signed entitlements" ;;
    "" | "com.apple.security.get-task-allow")
      printf '  FAIL  %-46s no audio-input: voice cannot listen\n' "signed entitlements"
      status=1 ;;
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
    echo "  armada.mgcrea.io, and only once you turn it on. It listens on one socket: the"
    echo "  MCP endpoint, on 127.0.0.1 only, and only while Settings ▸ Supervisor has it on."
  else
    echo "  Armada opens no connection of its own. It listens on one socket: the MCP"
    echo "  endpoint, on 127.0.0.1 only, and only while Settings ▸ Supervisor has it on."
  fi
  echo "  Nothing it reads leaves this Mac unless you point an agent at that endpoint."
  echo "  Its one entitlement is the microphone, open only while voice is listening."
  echo "  This says nothing about the \`claude\` it spawns, which talks to Anthropic"
  echo "  on your own sign-in — see SECURITY.md."
else
  echo "  Audit failed — see SECURITY.md for what this claim is load-bearing for."
fi
echo ""
exit "$status"
