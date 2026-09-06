---
name: register-builder
description: "Ask the project's manager session to adopt this pane as a builder. Use when the operator says 'register this session with the manager', 'register as a builder', 'become a builder', 'hand this tab to the manager', or names the issue number this session should be registered under. Do not use to act as the manager yourself, and do not use to resume or continue builder work — that starts only after the manager sends a brief."
---

# Register as a builder

You are a session in a herdr tab that wants the manager to adopt it. This skill's entire job is
to make the request, then stop.

1. **Resolve `mgr`.** `~/.claude/skills/manager/bin/mgr` is the installed path. If it is not
   there, try `$MGR paths` (when `MGR` is already exported) or `command -v mgr`.

2. **Run the request.**

   ```bash
   <mgr> register [N]
   ```

   Pass `N` only when this session already knows which issue it is working on. Omit it
   otherwise — the manager fills it in later.

3. **Relay the result.** On success `mgr register` prints one JSON object mapping this pane, the
   manager it registered with, and the issue (if any). Report that mapping to the operator in one
   short line.

4. **Stop and wait.** Do not load `builder.md`, do not run any other `mgr` command, and do not
   resume whatever work this session was doing. `mgr bind` in particular is not yours to run yet:
   it is a step the manager's brief will tell you to take, and only on the branch where no issue
   exists yet. The manager will send that brief; only when it arrives do you start under
   `builder.md`, at its second or third opener.

5. **A refusal ends this skill too.** Exit `3` means the request was refused — relay the message
   verbatim and stop. Exit `1` or `2` are the same: report the message, do not retry on your own.
