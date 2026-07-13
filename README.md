<p align="center">
  <img src="docs/banner.svg" alt="AaaS — Agent as a Service, Hermes on autopilot" width="100%">
</p>

AaaS is a self-hosted platform for offering dedicated, isolated [Hermes Agent](https://hermes-agent.nousresearch.com) instances as personal AI assistants to your customers ("tenants"). Each tenant's agent runs in its own Docker container, so a tenant's data and conversations stay private — never shared with other tenants or with the platform operator.

The platform is run by two admin agents:

- **OpenCode admin** — an interactive assistant for hands-on operational work: onboarding and offboarding tenants, running platform health checks, and general maintenance. Used directly by the operator at their machine.
- **Hermes admin** — the same operational capabilities, reachable over Telegram for when the operator is away. It also acts as the notification bridge from tenants to the operator: when a tenant agent needs to flag something, it messages Hermes admin, which relays it to the operator over Telegram. This bridge is one-way, tenant to operator only.

`install.sh` sets up the platform side: it provisions the host, installs and configures Hermes as the Hermes admin agent, wires up opencode for the OpenCode admin agent, and enables a watchdog to keep the Hermes admin's gateway running. Onboarding and managing tenants happens afterward, through the two admin agents — not through `install.sh` directly.

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

- `/opt/aaas/platform` — the platform's own config and admin-agent state
- Node.js, npm, and Docker Engine, where supported — Docker is what tenant agents will later run in, once onboarded
- opencode, powering the OpenCode admin agent (and automated watchdog repair)
- Hermes Agent, from the official Nous Research installer — this becomes the Hermes admin agent
- Telegram gateway configuration for the Hermes admin agent, so the operator can reach it, and it can reach the operator, from anywhere
- the Hermes admin's gateway, running as an official system service
- the AaaS watchdog, keeping that gateway alive, running as an autostart systemd service
- timestamped watchdog alert folders under `/opt/aaas/platform/watchdog/alerts/`

## Requirements

- a Linux host with `bash`, `curl`, `git`, `systemd`, and outbound network access
- `sudo` or root access

Docker installs automatically on supported package managers. On anything else, install Docker yourself first and rerun the installer.

## Operating the Platform

Once installed, day-to-day operations — onboarding a tenant, offboarding one, checking platform health, and similar tasks — go through the two admin agents:

- At your machine, talk to the **OpenCode admin** directly.
- Away from your machine, message the **Hermes admin** on Telegram — same operational capabilities, reachable from anywhere.
- Tenant agents notify you by messaging the Hermes admin, which relays the message to you on Telegram. You don't reply to tenants through this channel.

## Installer Prompts

- primary Hermes provider (default `opencode-zen`) and model (default `big-pickle`)
- optional fallback provider (default `openrouter`) and model (default `free`)
- Telegram bot token for the Hermes admin, from BotFather
- Telegram allowed user IDs, comma-separated — the first one becomes the operator's home channel

## Install Location

```bash
AAAS_ROOT=/opt/aaas          # default
```

Override it for testing:

```bash
AAAS_ROOT="$HOME/aaas-test" bash install.sh
```

## Verification

The watchdog only gets enabled after these all check out:

- Hermes is installed and the `gateway` command is available
- Telegram token and allowlist are configured
- the Hermes admin's gateway system service is running
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
# AaaS watchdog status
sudo systemctl status aaas-watchdog.service

# Follow watchdog logs
tail -f /opt/aaas/platform/watchdog/watchdog.log

# Rerun the installer (safe, idempotent)
bash install.sh
```

For Hermes admin gateway status or general platform health, ask either admin agent directly rather than reaching for raw commands.

## Notes

Do not commit runtime secrets, logs, generated watchdog files, or alert folders. This repository holds preset files only — runtime state belongs under `/opt/aaas` on the target host.