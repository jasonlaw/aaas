---
name: write-report
description: Write a platform report after fixing or root-causing a real platform issue — one that looks like it stems from how this platform instance was originally built/set up, rather than something a tenant did. Use this whenever a health check, an operator session, or a watchdog-triggered session turns up a real problem and it gets fixed or diagnosed, so the finding survives past the current session for the human operator to act on (they own the setup process; this agent does not). Do not use for tenant-side mistakes, routine successful runs with no findings, or issues already fully described in an existing report.
---

# Write Report

Record one Markdown file per finding, updated in place if the same issue resurfaces later the same day. That's the whole skill.

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
last_updated_utc: "{YYYY-MM-DDTHH:MM:SSZ}"
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

## Update {HH:MM:SSZ} ({author})
Only present if the report was updated later the same day (see "Same-day
duplicate check" below). New findings, fix attempts, or root-cause revisions
go here, newest at the bottom. Frontmatter `status` is updated in place to
reflect the current state; the update log preserves the history of how it
got there.
```

`author` in frontmatter records who *created* the file and is never rewritten. Each `## Update` block records its own author inline — either agent may append to any same-day report on the same component regardless of who created it. No handoff or coordination step is needed; whoever finds the follow-up just appends under their own name.

## Same-day duplicate check

Before writing, check only *today's* reports — not the whole directory:

```
ls /opt/aaas/platform/reports/ | grep "^$(date -u +%Y%m%d)"
```

- No matches → skip straight to writing a new file. No further reads needed.
- Matches → open just those files (today's set is normally 0–3) and check `component` in frontmatter.
  - Same component found → **update that file** instead of creating a new one: append a `## Update {HH:MM:SSZ} ({author})` section, bump `last_updated_utc`, and update `status` in frontmatter if it changed (e.g. `diagnosed-only` → `fixed`). Author of the update need not match the file's original `author`.
  - No component match → new file as normal.

This check is scoped to today only — never scan the full reports history. Older reports on the same component are a separate, unrelated concern and are not deduplicated against; each day starts a fresh file for a given issue if it recurs.

## Rules

- Redact secrets: API keys, tokens, credentials, private URLs, tenant private data.
- One report per finding per day. Don't merge unrelated findings into one file to save time; do update the same file if it's the same finding recurring later today, regardless of who created it originally.
- If the fix is still just a live workaround and the real setup-level change hasn't been made yet, say so plainly in "Setup-level fix needed" rather than leaving it vague.
