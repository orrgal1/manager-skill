// mgr-status.test.ts — unit tests for the status-line extension's pure helpers.
// Run through test/mgr-status-unit.sh (which is what test/run.sh drives) or
// directly with `bun test test/mgr-status.test.ts`. No temp dirs, no fakes on
// PATH: statusText/guardState/hhmmZ are pure, so the ledger is a literal here.
import { describe, expect, test } from "bun:test";

import { guardState, hhmmZ, statusText } from "../extensions/mgr-status.ts";
import type { Ledger, Limit, Manager, Stalled, StatusEnv } from "../extensions/mgr-status.ts";

// The shape mirrors a real state.json (see the fixture in test/mgr-quota-smoke.sh,
// lines 48-69): providers with limits, managers keyed by manager_id, stalled rows.
const T0 = Date.UTC(2026, 8, 5, 12, 0, 0); // 2026-09-05T12:00:00Z
const RESET = Date.UTC(2026, 8, 5, 17, 0, 0); // 17:00Z

function limit(over: Partial<Limit> = {}): Limit {
  return {
    id: "anthropic:5h",
    used: 0.2,
    burn_per_hour: 0.2,
    projected_at_reset: 2.56,
    resets_at: RESET,
    fits: false,
    ...over,
  };
}

function stalled(over: Partial<Stalled> = {}): Stalled {
  return {
    pane_id: "w3:p9",
    provider: "anthropic",
    limit: "anthropic:5h",
    recovers_at: null,
    manager_id: "ws-w3",
    ...over,
  };
}

function manager(over: Partial<Manager> = {}): Manager {
  return { workspace_id: "w3", pane_id: "w3:p1", paused_by_operator: false, ...over };
}

function ledger(over: Partial<Ledger> = {}): Ledger {
  return {
    pid: 4242,
    tick_at: T0,
    interval_s: 60,
    providers: { anthropic: { recovers_at: null, limits: [limit({ fits: true })] } },
    managers: { "ws-w3": manager() },
    stalled: [],
    ...over,
  };
}

const BUILDER: StatusEnv = { paneId: "w3:p9", workspaceId: "w3", burn: false };
const RATE_LIMITED = "⏳ rate-limited on anthropic:5h, guard reignites after 17:00Z";
const GUARD_DOWN = " (guard stopped — run mgr guard start)";

describe("statusText: the stall", () => {
  test("recovers_at on the row wins", () => {
    const st = ledger({ stalled: [stalled({ recovers_at: RESET })] });
    expect(statusText(st, "running", BUILDER, T0).mgr).toBe(RATE_LIMITED);
  });

  test("falls back to the provider's recovers_at", () => {
    const st = ledger({
      providers: { anthropic: { recovers_at: RESET, limits: [] } },
      stalled: [stalled()],
    });
    expect(statusText(st, "running", BUILDER, T0).mgr).toBe(RATE_LIMITED);
  });

  test("falls back to the named limit's resets_at", () => {
    const st = ledger({
      providers: { anthropic: { recovers_at: null, limits: [limit({ resets_at: RESET })] } },
      stalled: [stalled()],
    });
    expect(statusText(st, "running", BUILDER, T0).mgr).toBe(RATE_LIMITED);
  });

  test("nothing known says so instead of inventing a time", () => {
    const st = ledger({
      providers: { anthropic: { recovers_at: null, limits: [limit({ resets_at: null })] } },
      stalled: [stalled()],
    });
    expect(statusText(st, "running", BUILDER, T0).mgr).toBe(
      "⏳ rate-limited on anthropic:5h, guard reignites when the quota renews",
    );
  });

  test("no limit attribution names the provider", () => {
    const st = ledger({ stalled: [stalled({ limit: null, recovers_at: RESET })] });
    expect(statusText(st, "running", BUILDER, T0).mgr).toBe(
      "⏳ rate-limited on anthropic, guard reignites after 17:00Z",
    );
  });

  test("a stopped guard is called out", () => {
    const st = ledger({ stalled: [stalled({ recovers_at: RESET })] });
    expect(statusText(st, "stopped", BUILDER, T0).mgr).toBe(RATE_LIMITED + GUARD_DOWN);
  });

  test("so is a stale one — nothing will reignite the pane either way", () => {
    const st = ledger({ stalled: [stalled({ recovers_at: RESET })] });
    expect(statusText(st, "stale", BUILDER, T0).mgr).toBe(RATE_LIMITED + GUARD_DOWN);
  });

  test("a running guard adds no suffix", () => {
    const st = ledger({ stalled: [stalled({ recovers_at: RESET })] });
    expect(statusText(st, "running", BUILDER, T0).mgr).not.toContain("guard stopped");
  });

  test("another pane's stall is not ours", () => {
    const st = ledger({ stalled: [stalled({ pane_id: "w3:p7", recovers_at: RESET })] });
    expect(statusText(st, "running", BUILDER, T0).mgr).toBeUndefined();
  });
});

describe("statusText: the operator pause", () => {
  const PAUSED = "⏸ project paused (mgr unpause to resume launches)";

  test("our manager row, found by workspace", () => {
    const st = ledger({ managers: { "ws-w3": manager({ paused_by_operator: true }) } });
    expect(statusText(st, "running", BUILDER, T0).mgr).toBe(PAUSED);
  });

  test("a manager session finds its own row by pane id", () => {
    const st = ledger({
      managers: { "ws-w3": manager({ workspace_id: "other", paused_by_operator: true }) },
    });
    const env: StatusEnv = { paneId: "w3:p1", workspaceId: undefined, burn: false };
    expect(statusText(st, "running", env, T0).mgr).toBe(PAUSED);
  });

  test("a builder with no workspace id falls back to its stall's manager_id", () => {
    const st = ledger({
      managers: { "ws-w3": manager({ workspace_id: "other", pane_id: "other:p1" }) },
      stalled: [stalled({ pane_id: "w3:p9" })],
    });
    // paused_by_operator false here, so nothing shows once the stall is gone
    expect(
      statusText(
        { ...st, stalled: [] },
        "running",
        { paneId: "w3:p9", workspaceId: undefined, burn: false },
        T0,
      ).mgr,
    ).toBeUndefined();
  });

  test("a stall outranks the pause", () => {
    const st = ledger({
      managers: { "ws-w3": manager({ paused_by_operator: true }) },
      stalled: [stalled({ recovers_at: RESET })],
    });
    expect(statusText(st, "running", BUILDER, T0).mgr).toBe(RATE_LIMITED);
  });

  test("not paused and not stalled shows nothing", () => {
    expect(statusText(ledger(), "running", BUILDER, T0).mgr).toBeUndefined();
  });

  test("no ledger at all shows nothing", () => {
    const out = statusText(null, "stopped", { ...BUILDER, burn: true }, T0);
    expect(out.mgr).toBeUndefined();
    expect(out.burn).toBeUndefined();
  });
});

describe("statusText: the burn item", () => {
  const unfit = ledger({ providers: { anthropic: { recovers_at: null, limits: [limit()] } } });

  test("off by default even with an over-limit projection", () => {
    expect(statusText(unfit, "running", BUILDER, T0).burn).toBeUndefined();
  });

  test("on, it reads like the guard's own reason sentence", () => {
    expect(statusText(unfit, "running", { ...BUILDER, burn: true }, T0).burn).toBe(
      "🔥 anthropic:5h 20% 0.2/h → 2.56× by 17:00Z",
    );
  });

  test("the worst projection wins", () => {
    const st = ledger({
      providers: {
        anthropic: {
          recovers_at: null,
          limits: [
            limit(),
            limit({ id: "anthropic:week", used: 0.9, burn_per_hour: 0.05, projected_at_reset: 3.1 }),
          ],
        },
      },
    });
    expect(statusText(st, "running", { ...BUILDER, burn: true }, T0).burn).toBe(
      "🔥 anthropic:week 90% 0.05/h → 3.1× by 17:00Z",
    );
  });

  test("a limit that fits is not news", () => {
    const st = ledger({
      providers: { anthropic: { recovers_at: null, limits: [limit({ fits: true })] } },
    });
    expect(statusText(st, "running", { ...BUILDER, burn: true }, T0).burn).toBeUndefined();
  });

  test("an unknown reset omits the deadline rather than printing a fake one", () => {
    const st = ledger({
      providers: { anthropic: { recovers_at: null, limits: [limit({ resets_at: null })] } },
    });
    expect(statusText(st, "running", { ...BUILDER, burn: true }, T0).burn).toBe(
      "🔥 anthropic:5h 20% 0.2/h → 2.56×",
    );
  });

  test("the burn shows next to a stall, not instead of it", () => {
    const st = ledger({
      providers: { anthropic: { recovers_at: null, limits: [limit()] } },
      stalled: [stalled({ recovers_at: RESET })],
    });
    const out = statusText(st, "running", { ...BUILDER, burn: true }, T0);
    expect(out.mgr).toBe(RATE_LIMITED);
    expect(out.burn).toBe("🔥 anthropic:5h 20% 0.2/h → 2.56× by 17:00Z");
  });
});

describe("guardState", () => {
  const alive = () => true;
  const dead = () => false;

  test("a dead pid is a stopped guard", () => {
    expect(guardState(ledger(), T0, dead)).toBe("stopped");
  });

  test("a live pid with a fresh tick is running", () => {
    expect(guardState(ledger({ tick_at: T0 - 1000 }), T0, alive)).toBe("running");
  });

  test("five intervals is still running", () => {
    expect(guardState(ledger({ tick_at: T0 - 300000 }), T0, alive)).toBe("running");
  });

  test("older than five intervals is stale", () => {
    expect(guardState(ledger({ tick_at: T0 - 300001 }), T0, alive)).toBe("stale");
  });

  test("a live pid that never ticked is stale", () => {
    expect(guardState(ledger({ tick_at: 0 }), T0, alive)).toBe("stale");
  });

  test("no pid is a stopped guard", () => {
    expect(guardState(ledger({ pid: null }), T0, alive)).toBe("stopped");
  });

  test("no ledger is a stopped guard", () => {
    expect(guardState(null, T0, alive)).toBe("stopped");
  });
});

describe("hhmmZ", () => {
  test("zero-pads both fields", () => {
    expect(hhmmZ(Date.UTC(2026, 8, 5, 7, 5, 0))).toBe("07:05Z");
  });

  test("midnight is 00:00Z", () => {
    expect(hhmmZ(Date.UTC(2026, 8, 5, 0, 0, 0))).toBe("00:00Z");
  });

  test("seconds are dropped, not rounded up", () => {
    expect(hhmmZ(Date.UTC(2026, 8, 5, 17, 0, 59))).toBe("17:00Z");
  });
});
