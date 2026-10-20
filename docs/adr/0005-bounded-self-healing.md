# ADR-0005: Systemd-native health loop with bounded LLM repair

**Status:** Proposed

## Context
The current `watchdog.sh`, polled every 20 seconds, creates a new alert and starts a synchronous, untimed `opencode run` on every failed cycle. Several problems follow:
- Repair runs pile up and LLM costs grow without limit.
- Alert folders accumulate.
- The operator is never told anything, because the Telegram path is the gateway that is down.

## Decision
- Crash restarts are left to systemd: `Restart=on-failure` and `StartLimitBurst`.
- `aaas-health.timer` runs every 60 seconds and executes named checks. It is single-run via `flock`.
- An incident state machine persists `/var/lib/aaas/incidents/<check>.json`, so there is at most one open incident per check.
- Escalation per incident:
  1. Retry.
  2. Restart through `aaasd`.
  3. Open an incident and **notify the operator out-of-band** (ADR-0004).
  4. Run OpenCode with the `repair` permission profile, `timeout 15m`, at most 3 attempts, with backoff of 5, 20, then 60 minutes.
  5. Escalate to "needs human" and stop.
- The operator is notified again on resolution. A report is written through the `write-report` skill.

## Consequences
- LLM cost per incident and repair concurrency are both bounded.
- The operator always hears about an outage.
- Incidents are structured data, so they can be queried with `aaas incidents`.
