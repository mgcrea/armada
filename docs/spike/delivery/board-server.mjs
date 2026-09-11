#!/usr/bin/env node
// THROWAWAY SPIKE: can an MCP server reach an agent that is WAITING?
// Zero dependencies. Newline-delimited JSON-RPC 2.0 over stdin/stdout. stdout is the
// protocol channel, so every diagnostic goes to stderr and BOARD_LOG.
//
//   BOARD_FILE     shared JSON state, so separately started copies see one board
//   BOARD_LOG      server log
//   BOARD_TAG      log prefix
//   BOARD_CHANNEL  "1" to push new posts as notifications/claude/channel instead of
//                  notifications/message (Claude Code, interactive sessions only)

import { appendFileSync, existsSync, readFileSync, watchFile, writeFileSync } from "node:fs";

const BOARD = process.env.BOARD_FILE ?? "/tmp/spike-board.json";
const LOG = process.env.BOARD_LOG ?? "/tmp/spike-board.log";
const TAG = process.env.BOARD_TAG ?? "server";
const CHANNEL = process.env.BOARD_CHANNEL === "1";

const log = (...parts) => {
  const line = `${new Date().toISOString()} [${TAG}] ${parts.join(" ")}\n`;
  process.stderr.write(line);
  try {
    appendFileSync(LOG, line);
  } catch {}
};

const readBoard = () => {
  try {
    return JSON.parse(readFileSync(BOARD, "utf8"));
  } catch {
    return { messages: [] };
  }
};
if (!existsSync(BOARD)) writeFileSync(BOARD, JSON.stringify({ messages: [] }));

const send = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");
const notify = (method, params) => send({ jsonrpc: "2.0", method, params });

// Push new posts. watchFile (stat polling) rather than fs.watch, which misses atomic
// write-and-rename on macOS.
let lastCount = readBoard().messages.length;
watchFile(BOARD, { interval: 300 }, () => {
  const now = readBoard();
  if (now.messages.length === lastCount) return;
  const fresh = now.messages.slice(lastCount);
  lastCount = now.messages.length;
  for (const m of fresh) {
    const text = `NEW BOARD MESSAGE from ${m.from}: ${m.text}`;
    if (CHANNEL) {
      log("board changed, emitting notifications/claude/channel");
      notify("notifications/claude/channel", { content: text, meta: { source: "board", from: m.from } });
    } else {
      log("board changed, emitting notifications/message");
      notify("notifications/message", { level: "info", logger: "board", data: text });
    }
  }
});

// Tested whether an MCP server's instructions make a model check unprompted. They didn't.
const INSTRUCTIONS =
  "IMPORTANT: A shared message board connects you to other agents. " +
  "At the START of every single turn, before doing anything else, you MUST call " +
  "the board_read tool to check for messages from other agents. Messages there " +
  "are addressed to you and may change what you are supposed to do.";

const TOOLS = [
  {
    name: "board_read",
    description: "Read all messages on the shared agent board.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "board_post",
    description: "Post a message to the shared agent board.",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string" }, from: { type: "string" } },
      required: ["text"],
    },
  },
  {
    name: "board_wait",
    description:
      "Block until a new message appears on the board, or until the timeout expires. " +
      "Returns the new messages, or a timeout notice.",
    inputSchema: {
      type: "object",
      properties: { seconds: { type: "number", description: "Maximum seconds to wait" } },
    },
    annotations: { readOnlyHint: true },
  },
];

const textResult = (s) => ({ content: [{ type: "text", text: s }] });

// Long-poll: the one mechanism that reached a waiting agent in both Claude Code and Codex.
const boardWait = async (seconds) => {
  const started = Date.now();
  const deadline = started + seconds * 1000;
  const startCount = readBoard().messages.length;
  log(`board_wait START seconds=${seconds} count=${startCount}`);
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 500));
    const now = readBoard();
    if (now.messages.length > startCount) {
      const waited = ((Date.now() - started) / 1000).toFixed(1);
      log(`board_wait WOKE after ${waited}s`);
      return textResult(
        `After waiting ${waited}s, ${now.messages.length - startCount} new message(s):\n` +
          JSON.stringify(now.messages.slice(startCount), null, 2),
      );
    }
  }
  const waited = ((Date.now() - started) / 1000).toFixed(1);
  log(`board_wait TIMEOUT after ${waited}s`);
  return textResult(`Waited ${waited}s, no new messages.`);
};

const handle = async ({ method, params }) => {
  if (method === "initialize") {
    log(`initialize from ${JSON.stringify(params?.clientInfo)} proto=${params?.protocolVersion}`);
    return {
      // Echo the client's own protocol version; this spike doesn't test negotiation.
      protocolVersion: params?.protocolVersion ?? "2025-06-18",
      capabilities: {
        tools: { listChanged: true },
        logging: {},
        ...(CHANNEL ? { experimental: { "claude/channel": {} } } : {}),
      },
      serverInfo: { name: "board", version: "0.0.1" },
      instructions: INSTRUCTIONS,
    };
  }
  if (method === "tools/list") return { tools: TOOLS };
  if (method === "tools/call") {
    const name = params?.name;
    const args = params?.arguments ?? {};
    log(`tools/call ${name} ${JSON.stringify(args)}`);
    if (name === "board_read") {
      const board = readBoard();
      return textResult(
        board.messages.length
          ? `Board has ${board.messages.length} message(s):\n${JSON.stringify(board.messages, null, 2)}`
          : "Board is empty.",
      );
    }
    if (name === "board_post") {
      const board = readBoard();
      board.messages.push({ from: args.from ?? "unknown", text: args.text, at: new Date().toISOString() });
      writeFileSync(BOARD, JSON.stringify(board, null, 2));
      return textResult(`Posted. Board now has ${board.messages.length} message(s).`);
    }
    if (name === "board_wait") return await boardWait(args.seconds ?? 60);
    return { content: [{ type: "text", text: `unknown tool ${name}` }], isError: true };
  }
  if (method === "ping") return {};
  if (method === "resources/list") return { resources: [] };
  if (method === "prompts/list") return { prompts: [] };
  return null;
};

let buf = "";
process.stdin.on("data", async (chunk) => {
  buf += chunk;
  const lines = buf.split("\n");
  buf = lines.pop() ?? "";
  for (const line of lines) {
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      log(`unparseable: ${line.slice(0, 120)}`);
      continue;
    }
    if (msg.id === undefined) {
      log(`notification in: ${msg.method}`);
      continue;
    }
    try {
      const result = await handle(msg);
      send(
        result === null
          ? { jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: `no method ${msg.method}` } }
          : { jsonrpc: "2.0", id: msg.id, result },
      );
    } catch (err) {
      log(`handler threw: ${err?.stack ?? err}`);
      send({ jsonrpc: "2.0", id: msg.id, error: { code: -32603, message: String(err) } });
    }
  }
});

process.stdin.on("end", () => {
  log("stdin closed, exiting");
  process.exit(0);
});
log(`started, board=${BOARD}, channel=${CHANNEL}`);
