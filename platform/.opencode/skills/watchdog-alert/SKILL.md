---
name: watchdog-alert
description: >
  Route and resolve an AaaS watchdog alert. Triggers whenever opencode is
  invoked with a prompt referencing an "AaaS watchdog alert" and an alert
  folder path. Use this whenever the watchdog hands off a failure for any
  monitored target (Hermes gateway, Docker engine, or any future check) —
  the alert_code inside alert.txt determines which recovery skill to use.
---

# Watchdog Alert

## Trigger
Prompt references an alert folder path and nothing else. Read `alert.txt`
in that folder — it has `alert_code`, `timestamp_utc`, `message`, and
possibly extra target-specific fields (e.g. `gateway_unit`).

## Steps

1. Read `alert.txt`.
2. Find the skill named `<alert_code>-recovery`. If it doesn't exist, skip
   to step 4 and note the missing skill instead of a fix.
3. Follow that skill to diagnose and fix the issue, using the fields from
   `alert.txt` it needs.
4. Use the write-report skill to document the incident.
5. Only after the report exists, remove the alert folder — unless you're
   unsure recovery succeeded, in which case leave it in place as a signal
   that the incident needs a human look.

Do not remove the folder before step 4. It's the only record of the
incident if anything above fails partway through.