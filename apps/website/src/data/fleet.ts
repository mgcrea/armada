/**
 * The example fleet every drawing on the homepage is made from: the hero's list,
 * the menu bar panel, the window, the plan limits and the supervisor's answer.
 * One module, so an account named in one drawing has the same session count in
 * the next, and the headline's "Nineteen" is a sum rather than a claim.
 *
 * Every title, project and figure here is invented, and each drawing's caption
 * says so. What is not invented is the vocabulary. The state labels are the app's
 * own (`label` in apps/apple/Armada/Session.swift and CodexSession.swift), the
 * dot colours follow the menu bar rule that only a waiting session rings, and
 * "permission prompt" is the `waitingFor` text Claude Code writes for one (see
 * docs/claude-code-sessions.md).
 */

export const STATE = {
  waiting: { label: "Waiting for you", dot: "bg-warn", ink: "text-warn" },
  runningTool: { label: "Running a tool", dot: "bg-ok", ink: "text-ok-ink" },
  working: { label: "Working", dot: "bg-ok", ink: "text-ok-ink" },
  awaitingInput: { label: "Waiting for input", dot: "bg-fg-dim", ink: "text-fg-dim" },
  idle: { label: "Idle", dot: "bg-fg-muted", ink: "text-fg-muted" },
} as const;

export type SessionState = keyof typeof STATE;

export interface ExampleSession {
  title: string;
  project: string;
  account: string;
  age: string;
  /** Absent for Codex, which records no process id and so has no Focus target. */
  host?: string;
  state: SessionState;
  waitingFor?: string;
  context: string;
}

export const ACCOUNTS = [
  { name: "~/.claude", vendor: "Claude Code", sessions: 11 },
  { name: "~/.claude-personal", vendor: "Claude Code", sessions: 3 },
  { name: "~/.claude-acme", vendor: "Claude Code", sessions: 1 },
  { name: "~/.codex", vendor: "Codex", sessions: 4 },
] as const;

/** 19. The hero's headline spells it out in words, so change both together. */
export const TOTAL_SESSIONS = ACCOUNTS.reduce((n, a) => n + a.sessions, 0);

/** Ordered by what needs you, which is the app's own default sort. */
export const SESSIONS: ExampleSession[] = [
  {
    title: "Migrate the billing webhooks",
    project: "api-gateway",
    account: "~/.claude",
    age: "6m",
    host: "VS Code",
    state: "waiting",
    waitingFor: "permission prompt",
    context: "71%",
  },
  {
    title: "Audit the loopback listener",
    project: "swift-mcp-kit",
    account: "~/.claude",
    age: "31m",
    host: "Terminal",
    state: "runningTool",
    context: "12%",
  },
  {
    title: "Rework the transcript condenser",
    project: "armada",
    account: "~/.claude",
    age: "4m",
    host: "VS Code",
    state: "working",
    context: "38%",
  },
  {
    title: "Write the supervisor brief",
    project: "armada",
    account: "~/.claude",
    age: "48m",
    host: "VS Code",
    state: "working",
    context: "compacted once",
  },
  {
    title: "Split the settings scaffold",
    project: "support-kit",
    account: "~/.claude",
    age: "1h",
    host: "VS Code",
    state: "working",
    context: "56%",
  },
  {
    title: "Document the licence flow",
    project: "armada",
    account: "~/.claude",
    age: "3h",
    host: "Terminal",
    state: "idle",
    context: "19%",
  },
  {
    title: "Port the rollout reader",
    project: "armada",
    account: "~/.codex",
    age: "9m",
    state: "working",
    context: "44%",
  },
  {
    title: "Draft the release checklist",
    project: "bastion",
    account: "~/.claude-acme",
    age: "2h",
    host: "Terminal",
    state: "idle",
    context: "23%",
  },
];

/**
 * An element a drawing needs, or a failed build. A drawing that indexes past the
 * example data should stop the deploy rather than render an empty row.
 */
export function at<T>(items: readonly T[], index: number): T {
  const item = items[index];
  if (item === undefined) throw new Error(`fleet.ts: no example at index ${index}`);
  return item;
}

export const sessionsOf = (account: string) => SESSIONS.filter((s) => s.account === account);

export const accountOf = (name: string) => ACCOUNTS.find((a) => a.name === name)!;

/** A window's reading. `pace` is where an even pace would have used by now. */
export interface ExampleWindow {
  label: string;
  used: number;
  pace: number;
  reset: string;
}

export interface ExampleLimits {
  account: string;
  source: "live" | "cache";
  age: string;
  windows: ExampleWindow[];
}

export const LIMITS: ExampleLimits[] = [
  {
    account: "~/.claude",
    source: "live",
    age: "12s ago",
    windows: [
      { label: "5-hour window", used: 41, pace: 52, reset: "resets 14:00" },
      { label: "7-day window", used: 62, pace: 57, reset: "resets Sun" },
    ],
  },
  {
    account: "~/.claude-personal",
    source: "live",
    age: "40s ago",
    windows: [
      { label: "5-hour window", used: 88, pace: 64, reset: "resets 12:30" },
      { label: "7-day window", used: 94, pace: 78, reset: "resets Fri" },
    ],
  },
  {
    account: "~/.claude-acme",
    source: "cache",
    age: "6h old",
    windows: [
      { label: "5-hour window", used: 17, pace: 30, reset: "reset unknown" },
      { label: "7-day window", used: 30, pace: 41, reset: "resets Mon" },
    ],
  },
];

/** Fill by how close a window is to its limit, not by vendor or account. */
export const fillFor = (w: ExampleWindow, source: ExampleLimits["source"]) =>
  source === "cache"
    ? "bg-fg-muted"
    : w.used >= 90
      ? "bg-danger"
      : w.used >= 80
        ? "bg-warn"
        : "bg-ok";
