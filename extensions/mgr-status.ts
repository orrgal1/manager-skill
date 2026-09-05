// mgr-status.ts — omp status-line indicator for a quota-stalled session.
//
// A builder pane whose turn died on a provider 429 looks idle: the transcript
// stops mid-turn and nothing on screen says why, or that mgr-guard will reignite
// it. This extension puts that on the status line, and only there. It never
// prompts, never sends a message, never registers a tool: it is UI-only and
// never model-facing, so a stalled session's context is untouched by it.
//
// It reads mgr-guard's ledger,
//   ${MGR_STATE_DIR:-${XDG_STATE_HOME:-~/.local/state}/mgr-guard}/state.json
// polling it by mtime, and uses these fields (all written by bin/mgr-guard):
//   pid, tick_at, interval_s     — daemon liveness, mirrored from `mgr-guard status`
//   stalled[]                    — pane_id, provider, limit, recovers_at
//   providers.<p>.recovers_at    — when the provider itself comes back
//   providers.<p>.limits[]       — id, used, burn_per_hour, projected_at_reset,
//                                  resets_at, fits (the burn item)
//   managers.<id>                — workspace_id, pane_id, paused_by_operator
// Nothing here writes to the ledger, and a missing or half-written file is a
// no-op (the previous reading is kept until the next tick parses).
//
// Env:
//   HERDR_PANE_ID          this pane's id; without it the extension does nothing
//   HERDR_WORKSPACE_ID     used to find this session's manager row (the pause)
//   MGR_STATE_DIR          ledger directory override (same knob as bin/mgr-guard)
//   MGR_STATUS_INTERVAL_S  poll seconds, positive integer, default 5
//   MGR_STATUS_BURN=1      also show the burn projection item ("mgr-burn")

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// ------------------------------------------------------------------ types
//
// Declared locally on purpose: this file is loaded straight off disk by omp and
// is run standalone by `bun test`, so it must not import the host package.

export type Limit = {
  id?: string;
  used?: number | null;
  burn_per_hour?: number | null;
  projected_at_reset?: number | null;
  resets_at?: number | null;
  fits?: boolean;
};

export type Provider = {
  recovers_at?: number | null;
  limits?: Limit[];
};

export type Stalled = {
  pane_id?: string;
  provider?: string;
  limit?: string | null;
  recovers_at?: number | null;
  manager_id?: string | null;
};

export type Manager = {
  workspace_id?: string;
  pane_id?: string;
  paused_by_operator?: boolean;
};

export type Ledger = {
  pid?: number | null;
  tick_at?: number | null;
  interval_s?: number | null;
  providers?: Record<string, Provider>;
  managers?: Record<string, Manager>;
  stalled?: Stalled[];
};

export type GuardState = "running" | "stale" | "stopped";

export type StatusEnv = {
  paneId: string;
  workspaceId: string | undefined;
  burn: boolean;
};

type Ctx = {
  hasUI: boolean;
  ui: { setStatus(key: string, text: string | undefined): void };
  setInterval(fn: () => void, ms: number): unknown;
  clearTimer(t: unknown): void;
};

type ExtensionAPI = {
  on(event: string, handler: (event: unknown, ctx: Ctx) => unknown): void;
};

const MGR_KEY = "mgr";
const BURN_KEY = "mgr-burn";
const GUARD_DOWN = " (guard stopped — run mgr guard start)";
const PAUSED = "⏸ project paused (mgr unpause to resume launches)";
const DEFAULT_INTERVAL_S = 5;
const DEFAULT_GUARD_INTERVAL_S = 60; // bin/mgr-guard's own default

// ------------------------------------------------------------------ helpers

/** UTC HH:MM of an epoch-ms instant, zero-padded, with the Z the guard prints. */
export function hhmmZ(ms: number): string {
  const d = new Date(ms);
  const h = String(d.getUTCHours()).padStart(2, "0");
  const m = String(d.getUTCMinutes()).padStart(2, "0");
  return `${h}:${m}Z`;
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

/** Same verdict `mgr-guard status` derives: a live pid with a fresh tick. */
export function guardState(
  state: Ledger | null,
  now: number,
  alive: (pid: number) => boolean,
): GuardState {
  const pid = num(state?.pid);
  if (pid === null || pid <= 0 || !alive(pid)) return "stopped";
  const tick = num(state?.tick_at) ?? 0;
  const iv = num(state?.interval_s);
  const interval = iv !== null && iv > 0 ? iv : DEFAULT_GUARD_INTERVAL_S;
  if (tick > 0 && now - tick <= interval * 5 * 1000) return "running";
  return "stale";
}

/** The managers row this session belongs to: by workspace, by pane, or by attribution. */
function ownManager(state: Ledger, env: StatusEnv): Manager | undefined {
  const rows = Object.values(state.managers ?? {});
  if (env.workspaceId) {
    const byWorkspace = rows.find((m) => m?.workspace_id === env.workspaceId);
    if (byWorkspace) return byWorkspace;
  }
  const byPane = rows.find((m) => m?.pane_id === env.paneId);
  if (byPane) return byPane;
  const mine = (state.stalled ?? []).find((s) => s?.pane_id === env.paneId);
  const id = mine?.manager_id;
  if (id) return (state.managers ?? {})[id];
  return undefined;
}

/** When the guard expects the quota back: the row, the provider, then the limit. */
function recoveryAt(state: Ledger, row: Stalled): number | null {
  const rowAt = num(row.recovers_at);
  if (rowAt !== null) return rowAt;
  const provider = row.provider ? state.providers?.[row.provider] : undefined;
  const providerAt = num(provider?.recovers_at);
  if (providerAt !== null) return providerAt;
  if (row.limit) {
    const limit = (provider?.limits ?? []).find((l) => l?.id === row.limit);
    const limitAt = num(limit?.resets_at);
    if (limitAt !== null) return limitAt;
  }
  return null;
}

function burnText(state: Ledger): string | undefined {
  let worst: Limit | undefined;
  let worstAt = -Infinity;
  for (const provider of Object.values(state.providers ?? {})) {
    for (const limit of provider?.limits ?? []) {
      if (limit?.fits !== false) continue;
      const at = num(limit.projected_at_reset) ?? -Infinity;
      if (worst === undefined || at > worstAt) {
        worst = limit;
        worstAt = at;
      }
    }
  }
  if (worst === undefined) return undefined;
  const pct = Math.round((num(worst.used) ?? 0) * 100);
  const by = num(worst.resets_at);
  return (
    `🔥 ${worst.id} ${pct}% ${num(worst.burn_per_hour) ?? 0}/h` +
    ` → ${num(worst.projected_at_reset) ?? 0}×` +
    (by === null ? "" : ` by ${hhmmZ(by)}`)
  );
}

/**
 * The whole indicator as a pure function of the ledger: a stall on this pane
 * outranks an operator pause, and a dead guard is worth saying out loud because
 * nothing will reignite the pane until it is back.
 */
export function statusText(
  state: Ledger | null,
  guard: GuardState,
  env: StatusEnv,
  _now: number,
): { mgr: string | undefined; burn: string | undefined } {
  if (state === null) return { mgr: undefined, burn: undefined };

  const row = (state.stalled ?? []).find((s) => s?.pane_id === env.paneId);
  let mgr: string | undefined;
  if (row !== undefined) {
    const on = row.limit ?? row.provider;
    const at = recoveryAt(state, row);
    const when = at === null ? "when the quota renews" : `after ${hhmmZ(at)}`;
    mgr = `⏳ rate-limited on ${on}, guard reignites ${when}`;
    if (guard !== "running") mgr += GUARD_DOWN;
  } else if (ownManager(state, env)?.paused_by_operator === true) {
    mgr = PAUSED;
  }

  return { mgr, burn: env.burn ? burnText(state) : undefined };
}

// ------------------------------------------------------------------ runtime

function stateFile(): string {
  const dir =
    process.env.MGR_STATE_DIR ||
    path.join(
      process.env.XDG_STATE_HOME || path.join(process.env.HOME || os.homedir(), ".local", "state"),
      "mgr-guard",
    );
  return path.join(dir, "state.json");
}

function pollSeconds(): number {
  const raw = process.env.MGR_STATUS_INTERVAL_S;
  if (raw !== undefined && /^[0-9]+$/.test(raw.trim())) {
    const n = Number(raw.trim());
    if (n > 0) return n;
  }
  return DEFAULT_INTERVAL_S;
}

// Same test as `kill -0 "$pid"` in mgr-guard status: any failure, ESRCH or EPERM,
// is "not our running daemon".
function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export default function mgrStatus(pi: ExtensionAPI): void {
  pi.on("session_start", (_event, ctx) => {
    const paneId = process.env.HERDR_PANE_ID;
    if (!ctx.hasUI || !paneId) return; // print/headless/subagent, or not a herdr pane

    // `mgr launch` passes --extension <root>/extensions/mgr-status.ts and
    // install.sh symlinks the same file into the omp extensions dir; both can
    // apply to one session and the two paths defeat omp's absolute-path dedup.
    const marker = Symbol.for("mgr-status");
    const g = globalThis as unknown as Record<symbol, unknown>;
    if (g[marker]) return;
    g[marker] = true;

    const file = stateFile();
    const env: StatusEnv = {
      paneId,
      workspaceId: process.env.HERDR_WORKSPACE_ID || undefined,
      burn: process.env.MGR_STATUS_BURN === "1",
    };

    let cached: Ledger | null = null;
    let mtime: number | null = null;
    // last value pushed per key, so an unchanged reading costs no repaint and a
    // clear is sent exactly once
    let shownMgr: string | undefined;
    let shownBurn: string | undefined;

    const poll = () => {
      try {
        let stat: fs.Stats | null = null;
        try {
          stat = fs.statSync(file);
        } catch {
          stat = null; // ENOENT: no guard has ever run here, or the dir was wiped
        }
        if (stat === null) {
          cached = null;
          mtime = null;
        } else if (stat.mtimeMs !== mtime) {
          try {
            cached = JSON.parse(fs.readFileSync(file, "utf8")) as Ledger;
            mtime = stat.mtimeMs;
          } catch {
            // a half-written file: keep the last good reading and leave the
            // mtime memo alone so the next tick re-reads it
          }
        }
        const now = Date.now();
        const text = statusText(cached, guardState(cached, now, pidAlive), env, now);
        if (text.mgr !== shownMgr) {
          shownMgr = text.mgr;
          ctx.ui.setStatus(MGR_KEY, text.mgr);
        }
        if (text.burn !== shownBurn) {
          shownBurn = text.burn;
          ctx.ui.setStatus(BURN_KEY, text.burn);
        }
      } catch {
        // never throw out of a timer: an uncaught throw here tears the session down
      }
    };

    poll();
    const timer = ctx.setInterval(poll, pollSeconds() * 1000);

    pi.on("session_shutdown", () => {
      ctx.clearTimer(timer);
      ctx.ui.setStatus(MGR_KEY, undefined);
      ctx.ui.setStatus(BURN_KEY, undefined);
      delete g[marker];
    });
  });
}
