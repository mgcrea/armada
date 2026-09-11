// THROWAWAY SPIKE. A minimal stdio MCP server that logs what it can learn about the
// session that started it: its parent PID and CLAUDE_CODE_SESSION_ID. Answers just enough
// JSON-RPC (initialize, tools/list, ping) for Claude Code to keep it connected.
const fs = require("fs");

fs.appendFileSync(
  process.env.ID_LOG,
  JSON.stringify({
    at: new Date().toISOString(),
    probe_pid: process.pid,
    ppid: process.ppid,
    CLAUDE_CODE_SESSION_ID: process.env.CLAUDE_CODE_SESSION_ID || null,
  }) + "\n",
);

let buf = "";
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    if (msg.id === undefined) continue;
    let result = null;
    if (msg.method === "initialize") {
      result = {
        protocolVersion: (msg.params && msg.params.protocolVersion) || "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "idprobe", version: "0" },
      };
    } else if (msg.method === "tools/list") {
      result = { tools: [] };
    } else if (msg.method === "ping") {
      result = {};
    }
    const reply = result
      ? { jsonrpc: "2.0", id: msg.id, result }
      : { jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "unsupported" } };
    process.stdout.write(JSON.stringify(reply) + "\n");
  }
});
