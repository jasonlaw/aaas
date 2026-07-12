<p align="center">
  <img src="docs/banner.svg" alt="AaaS — Agent as a Service, Hermes on autopilot" width="100%">
</p>

AaaS is a self-hosted [Hermes Agent](https://hermes-agent.nousresearch.com) preset for an always-on, Telegram-accessible assistant. Point `install.sh` at a Linux box and it builds a production-style layout under `/opt/aaas`: it installs the runtime tools, installs and configures Hermes, starts the official messaging gateway, and — once everything checks out — turns on a watchdog to keep it that way.

The installer is idempotent. Something failed halfway through? Fix it and rerun — it picks up where it left off.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/jasonlaw/aaas/master/install.sh | bash
```

Prefer to read before you run?

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/jasonlaw/aaas/master/install.sh
less install.sh
bash install.sh
```

## What It Installs

- `/opt/aaas/platform` from this repository's `platform/` preset files
- Node.js, npm, and Docker Engine where supported
- opencode, for automated watchdog repair
- Hermes Agent, from the official Nous Research installer
- Telegram gateway configuration, written into `/opt/aaas/platform/.hermes/.env`
- the Hermes gateway, running as an official system service
- the AaaS watchdog, running as an autostart systemd service
- timestamped watchdog alert folders under `/opt/aaas/platform/watchdog/alerts/`

## Requirements

- a Linux host with `bash`, `curl`, `git`, `systemd`, and outbound network access
- `sudo` or root access

Docker installs automatically on supported package managers. On anything else, install Docker yourself first and rerun the installer.

## Design: One Repo, Hermes At Its Own Default Home

AaaS's own config/state lives under a single root, `/opt/aaas` by default. `HERMES_HOME` is deliberately **not** nested under it — Hermes is installed as the `aaas` service account and left at its own default location, `AAAS_HOME/.hermes` (e.g. `/opt/aaas/.hermes` if `aaas` was freshly created, or `/home/aaas/.hermes` if `aaas` pre-existed, per `/etc/passwd`). An earlier version of this installer pinned `HERMES_HOME` to a custom path under `platform/` and force-exported it everywhere (`/etc/environment`, `.bashrc`, a wrapper-level `export`) — that proved unreliable across shells/services and was removed in favor of just using Hermes's own default, which every process resolves identically from `/etc/passwd` with no extra plumbing.

```text
/opt/aaas/                     ← ROOT_DIR
└── platform/                  ← PLATFORM_DIR — install.sh-owned config & state
    ├── .env                   ← AAAS_ROOT, HERMES_HOME (informational; sourced by watchdog & the gateway's systemd EnvironmentFile)
    ├── .hermes/                ← staging dir ONLY — one-shot bootstrap files, NOT HERMES_HOME
    │   ├── config.yaml         ← staging copy, applied then backed up with a timestamp
    │   └── SOUL.md             ← staging copy, applied then backed up with a timestamp
    ├── .opencode/skills/       ← skills available to the admin opencode agent
    └── watchdog/
        ├── watchdog.sh
        ├── watchdog.log
        └── alerts/

AAAS_HOME/                     ← e.g. /opt/aaas or /home/aaas, resolved from /etc/passwd
└── .hermes/                   ← HERMES_HOME — Hermes's own default directory (untouched by install.sh)
    ├── hermes-agent/          ← Hermes code + venv (the actual install)
    ├── config.yaml            ← Hermes's generated config
    ├── SOUL.md                ← Hermes's agent identity
    ├── skills/                ← second external skills dir, merged in via config.yaml
    └── .env                   ← Telegram tokens, provider keys (Hermes-owned secrets)
```

Note the naming collision to watch for: `PLATFORM_DIR/.hermes/` and `AAAS_HOME/.hermes/` are two different directories that happen to share a name. The former is a git-tracked staging folder for one-shot bootstrap files; the latter is the real `HERMES_HOME`, created and owned entirely by Hermes itself. `install.sh` never writes into the latter except via the documented bootstrap-apply step below.

One rule holds throughout `install.sh`: **it never writes into `HERMES_HOME` behind Hermes's back.** `hermes setup` owns `config.yaml`, `.env`, and `SOUL.md` once installed — those are Hermes's files, holding real secrets. Everything install.sh itself needs to track (like `AAAS_ROOT` and the resolved `HERMES_HOME` path, for the watchdog and systemd) lives in `PLATFORM_DIR/.env`. Skills are surfaced from two places — `PLATFORM_DIR/.opencode/skills` (repo/install-managed) and `HERMES_HOME/skills` (Hermes-managed, e.g. self-created skills) — both listed in the staged `config.yaml`'s `skills.external_dirs`.

### Presetting Hermes without touching Hermes's files directly

Sometimes you *do* want to hand Hermes a starting config or persona before it ever runs `hermes setup`. Rather than patching `config.yaml`/`SOUL.md` directly, drop a small staging file in `PLATFORM_DIR/.hermes/` and let the installer apply it once, then clean up after itself:

| Staging file (in `PLATFORM_DIR/.hermes/`) | Applied to | Behavior |
|---|---|---|
| `config.yaml` | `HERMES_HOME/config.yaml` | deep-merged in; a commented-out top-level key (e.g. `#provider:`) comments that section out in `config.yaml` too |
| `SOUL.md` | `HERMES_HOME/SOUL.md` | copied in as-is (plain Markdown, no merge semantics) |

Both are optional and both are just files under `platform/.hermes/` in this repo, sharing the same filenames as their real Hermes counterparts (`config.yaml`, `SOUL.md`) — `config.yaml` ships tracked in git (its placeholders, `__PLATFORM_DIR__` and `__HERMES_HOME__`, are resolved by `install.sh` right after syncing, since both are only known once `AAAS_ROOT` is set and `AAAS_HOME` is resolved from `/etc/passwd`). Delete or edit it before running the installer to change what gets bootstrapped. Once applied, the staging file is renamed to a timestamped backup on the target host (e.g. `config.yaml.applied-20260712-041530`) rather than deleted, so there's an audit trail of what was bootstrapped and when.

Out of the box, the staged `config.yaml` merges in both external skills directories and comments out `provider`/`model` so `hermes setup` drives those interactively.

## Installer Prompts

- primary Hermes provider (default `opencode-zen`) and model (default `big-pickle`)
- optional fallback provider (default `openrouter`) and model (default `free`)
- Telegram bot token from BotFather
- Telegram allowed user IDs, comma-separated — the first one becomes the home channel

## Install Location

```bash
AAAS_ROOT=/opt/aaas          # default
```

Override it for testing:

```bash
AAAS_ROOT="$HOME/aaas-test" bash install.sh
```

## Hermes And Telegram

AaaS follows the official Hermes messaging gateway flow:

```bash
hermes gateway install --system
hermes gateway start --system
hermes gateway status --system
```

Telegram secrets and installer settings land in `/opt/aaas/platform/.hermes/.env`:

```env
PROVIDER=...
PROVIDER_MODEL=...
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ALLOWED_USERS=...
TELEGRAM_HOME_CHANNEL=...
FALLBACK_PROVIDER=...
FALLBACK_MODEL=...
FALLBACK_BASE_URL=...
FALLBACK_KEY_ENV=...
```

When fallback is enabled, the installer writes Hermes' documented top-level fallback chain into `/opt/aaas/platform/.hermes/config.yaml`:

```yaml
fallback_providers:
  - provider: "openrouter"
    model: "free"
```

`FALLBACK_BASE_URL` and `FALLBACK_KEY_ENV` are optional — only written when configured.

## Verification

The watchdog only gets enabled after these all check out:

- Hermes is installed and the `gateway` command is available
- Telegram token and allowlist are configured
- the Hermes gateway system service is running
- the AaaS watchdog system service can start

Something fails? The installer stops there — fix it and rerun the same command.

## Watchdog Alerts

When the watchdog spots a problem, it drops a timestamped alert folder:

```text
/opt/aaas/platform/watchdog/alerts/alert-YYYYmmdd-HHMMSS-PID/alert.txt
```

If `opencode` is available, the watchdog hands it the alert path and asks it to repair the issue. Once opencode has picked it up, it can remove the whole alert folder.

## Useful Commands

```bash
# Hermes gateway status
sudo env HERMES_HOME=/opt/aaas/platform/.hermes hermes gateway status --system

# AaaS watchdog status
sudo systemctl status aaas-watchdog.service

# Follow watchdog logs
tail -f /opt/aaas/platform/watchdog/watchdog.log

# Rerun the installer (safe, idempotent)
bash install.sh
```

## Project Layout

```text
.
├── install.sh
├── platform/
│   ├── .hermes/
│   │   ├── config.yaml
│   │   └── SOUL.md
│   ├── .opencode/
│   │   └── skills/
│   └── AGENTS.md
└── README.md
```

## Notes

Do not commit runtime secrets, logs, generated watchdog files, or alert folders. This repository holds preset files only — runtime state belongs under `/opt/aaas` on the target host.