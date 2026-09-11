#!/bin/bash
# THROWAWAY SPIKE. Startup time and idle memory of a tiny Swift program versus Node, for a
# process that runs once per agent session (an MCP relay, or a hook waiting for a message).
#
#   bash measure.sh
#   NODE=/path/to/node MCP_SDK_DIR=~/Projects/mgcrea/mgcrea-ai/mcp-a2a bash measure.sh
#
# NODE defaults to the node on PATH. Results from 2026-09-10 used Bastion's embedded Node:
#   apps/apple/.build/node-cache/node-v24.*-darwin-arm64/bin/node
# MCP_SDK_DIR, if set, is a package folder with @modelcontextprotocol/server and zod
# installed, to also measure Node with the MCP SDK loaded.
set -u
D="$(cd "$(dirname "$0")" && pwd)"
NODE="${NODE:-$(command -v node)}"
cd "$D" || exit 1

cat > hook.swift <<'EOF'
import Foundation
let sid = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"] ?? "-"
let input = FileHandle.standardInput.readDataToEndOfFile()
FileHandle.standardError.write("ppid=\(getppid()) sid=\(sid) bytes=\(input.count)\n".data(using: .utf8)!)
EOF
swiftc -O hook.swift -o hook || exit 1
echo "swift binary: $(stat -f %z hook 2>/dev/null || stat -c %s hook) bytes"
echo "node: $NODE $("$NODE" --version)"

python3 - "$D/hook" "$NODE" "${MCP_SDK_DIR:-}" <<'PY'
import re, statistics, subprocess, sys, time

hook, node, sdk = sys.argv[1], sys.argv[2], sys.argv[3]

def cold_start_ms(cmd, runs=15):
    samples = []
    for _ in range(runs):
        t = time.perf_counter()
        subprocess.run(cmd, input=b'{"hook_event_name":"Stop"}', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        samples.append((time.perf_counter() - t) * 1000)
    return round(statistics.median(samples), 1)

print("cold start, swift:", cold_start_ms([hook]), "ms")
print("cold start, node :", cold_start_ms([node, "-e",
      "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>process.stderr.write(String(process.ppid)))"]), "ms")

def idle(label, cmd, cwd=None):
    # stdin stays open, so each process sits blocked like an idle hook or relay.
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=cwd)
    time.sleep(5)
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
    vm = subprocess.run(["vmmap", "--summary", str(p.pid)], capture_output=True, text=True).stdout
    m = re.search(r"Physical footprint:\s+(\S+)", vm)
    print(f"{label:<28} RSS {int(rss) / 1024:5.1f} MB   physical footprint {m.group(1) if m else 'n/a'}")
    p.kill()

idle("idle, swift", [hook])
idle("idle, node bare", [node, "-e", "process.stdin.resume()"])
if sdk:
    idle("idle, node + MCP SDK + zod", [node, "--input-type=module", "-e",
         "await import('@modelcontextprotocol/server'); await import('@modelcontextprotocol/server/stdio'); await import('zod'); process.stdin.resume()"],
         cwd=sdk)
PY
