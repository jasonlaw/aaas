---
name: write-report
description: Write a platform report after fixing or root-causing a real platform issue — one that looks like it stems from how this platform instance was originally built/set up, rather than something a tenant did. Use this whenever a health check, an operator session, or a watchdog-triggered session turns up a real problem and it gets fixed or diagnosed, so the finding survives past the current session for the human operator to act on (they own the setup process; this agent does not). Do not use for tenant-side mistakes, routine successful runs with no findings, or issues already fully described in an existing report.
---

# Write Report

Record one Markdown file per finding. That's the whole skill.

## When to write one

Write a report the moment you fix or root-cause a real platform problem — not at the end of an unrelated task, not batched. One report per finding, even if several turn up in the same session.

Applies to exactly these triggers:

| trigger | when | who writes it |
|---|---|---|
| `healthcheck` | Routine/periodic health check turns up a real problem and it gets fixed | whichever agent ran the check — OpenCode admin or Hermes admin |
| `operator` | Mid-session with an operator, a real problem gets fixed — confirm with the operator first that a report should be written | whichever agent the operator is in session with — OpenCode admin or Hermes admin |
| `watchdog` | `aaas-watchdog.sh` invokes OpenCode after an automatic restart attempt fails, and the invoked session resolves or root-causes the issue | OpenCode admin agent (only agent the watchdog invokes) |

A "real problem" means: something about how this platform instance is set up — a systemd unit, a config file, a permission, an environment variable, a directory layout, a dependency version, anything that was put in place at build/setup time rather than during normal operation — is wrong, missing, or produced a broken state. As opposed to a one-off tenant mistake or a transient blip with no setup-level cause. If the cause is purely tenant-side, don't write a report. You don't need to know or guess which script or process originally created the broken thing — just describe the broken thing itself precisely; the human operator will trace it back to its source.

Skip the report only when nothing was actually found or fixed — a clean health check with zero findings needs no report.

## Where it goes

`/opt/aaas/platform/reports/{timestamp}_{short-task-name}_{status}.md`

- Timestamp: UTC, `YYYYMMDDTHHMMSSZ`.
- `short-task-name`: a few words, e.g. `mnemosyne-venv-broken`, `gateway-restart-fail`, `docker-nftables-gap`.
- `status`: `fixed`, `partial`, `diagnosed-only`, `cancelled`.
- Write directly into `reports/` — no subfolders.

## Format

```markdown
---
timestamp_utc: "{YYYY-MM-DDTHH:MM:SSZ}"
platform_version: "{contents of /opt/aaas/platform/VERSION}"
trigger: "healthcheck|operator|watchdog"
author: "opencode|hermes-admin"
status: "fixed|partial|diagnosed-only|cancelled"
component: "{e.g. gateway systemd unit, watchdog service, memory-provider config, docker network setup}"
---

# {Short Task Name}

## What happened
One or two sentences: what broke or was found broken.

## Root cause
The actual mechanism — the specific file, setting, permission, or state that's
responsible, described precisely. Not a symptom description; the cause.

## Fix applied
What was changed on this running system to resolve it right now, if anything.
Include exact commands or file edits. If nothing was changed live (diagnosis
only), say so.

## Setup-level fix needed
The concrete, permanent change the human operator should make to how this
platform is built/set up, so this doesn't recur on future installs —
described precisely enough to act on (what file, what value, what behavior,
before/after), even though this agent doesn't know or need to know which
script or process created it originally. This is the most important
section; the rest of the report exists to support it. If the live fix above
already *is* the correct permanent fix, say that explicitly.

## Evidence
Command output, log lines, error text that justifies the root cause claim.
Redact secrets (API keys, tokens, credentials).
```

Keep it terse. Every section should earn its place — no restating the SOP, no meta-commentary about the report itself.

## Rules

- Redact secrets: API keys, tokens, credentials, private URLs, tenant private data.
- One report per finding. Don't merge unrelated findings into one file to save time.
- If the fix is still just a live workaround and the real setup-level change hasn't been made yet, say so plainly in "Setup-level fix needed" rather than leaving it vague.
- Hermes admin writes its own reports directly, same as OpenCode — no handoff needed. If Hermes admin ever can't write to `/opt/aaas/platform/reports/` in some deployment, that's itself a setup-level bug: write it up as its own report (author OpenCode, since Hermes admin couldn't — see the invoke-opencode skill for how to hand it off correctly) rather than quietly routing around it.
- Before writing a new report, skim recent ones for the same component to avoid duplicating a known, already-reported issue:
  `ls -t /opt/aaas/platform/reports/ | head -20`
  If it's the same root cause as an existing report, don't write a new file — note the recurrence at the end of the existing one instead.