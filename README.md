# Agent as a Service

Agent as a Service, or AaaS, is a self-hosted Hermes Agent platform preset for an always-on Telegram-accessible assistant. The installer prepares a production-style Linux layout under `/opt/aaas`, installs the required runtime tools, configures Hermes Agent, starts the official Hermes messaging gateway, and enables a watchdog service after verification succeeds.

## What It Installs

The installer is idempotent, so it is safe to rerun after fixing a failed dependency or configuration issue.

It sets up:

- `/opt/aaas/platform` from this repository's `platform/` preset files
- Node.js and npm
- opencode for automated repair alerts
- Docker Engine where supported
- Hermes Agent from the official Nous Research installer
- Telegram gateway configuration in `/opt/aaas/platform/.hermes/.env`
- Hermes gateway as an official system service
- AaaS watchdog as an autostart systemd service
- Timestamped watchdog alert folders under `/opt/aaas/platform/watchdog/alerts/`

## Quick Install

Run the installer directly from the published repository:

```bash
curl -fsSL https://raw.githubusercontent.com/jasonlaw/aaas/master/install.sh | bash
```

If you prefer to review the installer first:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/jasonlaw/aaas/master/install.sh
less install.sh
bash install.sh
```

## Requirements

Use a Linux host with:

- `bash`
- `curl`
- `git`
- `sudo` or root access
- `systemd` for autostart services
- outbound network access

Docker is installed automatically on supported package managers. If your platform is not supported, install Docker manually and rerun the installer.

## Installer Prompts

During installation, AaaS asks for:

- primary Hermes provider selected from the official provider list, default `opencode-zen`
- primary model, default `big-pickle`
- optional Hermes fallback provider selected from the official provider list, default `openrouter`
- fallback model, default `free`
- Telegram bot token from BotFather
- Telegram allowed user IDs, comma-separated

The first allowed Telegram user ID is used as the initial home channel.

## Install Location

By default AaaS installs into:

```bash
/opt/aaas
```

Copyable environment form:

```bash
AAAS_ROOT=/opt/aaas
```

For testing, you can override the root directory:

```bash
AAAS_ROOT="$HOME/aaas-test" bash install.sh
```

## Hermes And Telegram

AaaS follows the official Hermes Agent messaging gateway flow:

```bash
hermes gateway install --system
hermes gateway start --system
hermes gateway status --system
```

Telegram secrets and AaaS installer settings are written to:

```text
/opt/aaas/platform/.hermes/.env
```

with:

```env
PROVIDER=...`r`nPROVIDER_MODEL=...`r`nTELEGRAM_BOT_TOKEN=...
TELEGRAM_ALLOWED_USERS=...
TELEGRAM_HOME_CHANNEL=...
FALLBACK_PROVIDER=...
FALLBACK_MODEL=...
FALLBACK_BASE_URL=...
FALLBACK_KEY_ENV=...
```


When fallback is enabled, the installer lets you choose a provider from the official Hermes provider list, accepts exact provider IDs, and includes a manual option for custom or newly added providers. It then writes Hermes' documented top-level fallback chain into:

```text
/opt/aaas/platform/.hermes/config.yaml
```

The managed block looks like:

```yaml
fallback_providers:
  - provider: "openrouter"
    model: "free"
```

`FALLBACK_BASE_URL` and `FALLBACK_KEY_ENV` are optional and are only written when configured.

## Verification

The installer only enables the AaaS watchdog after Hermes gateway verification succeeds. It checks that:

- Hermes is installed
- the gateway command is available
- Telegram token and allowlist are configured
- the Hermes gateway system service is running
- the AaaS watchdog system service can start

If a critical step fails, the installer stops. Fix the issue and rerun the same command.

## Watchdog Alerts

When the watchdog detects a problem, it creates a timestamped alert folder:

```text
/opt/aaas/platform/watchdog/alerts/alert-YYYYmmdd-HHMMSS-PID/alert.txt
```

If `opencode` is available, the watchdog invokes it with the alert path and asks it to repair the issue. After picking up the alert, opencode can remove the entire alert folder.

## Useful Commands

Check Hermes gateway status:

```bash
sudo env HERMES_HOME=/opt/aaas/platform/.hermes hermes gateway status --system
```

Check AaaS watchdog status:

```bash
sudo systemctl status aaas-watchdog.service
```

Follow watchdog logs:

```bash
tail -f /opt/aaas/platform/watchdog/watchdog.log
```

Rerun the installer:

```bash
bash install.sh
```

## Project Layout

```text
.
├── install.sh
├── platform/
│   ├── .hermes/
│   │   └── config.yml
│   ├── .opencode/
│   │   └── skills/
│   └── AGENTS.md
└── README.md
```

## Notes

Do not commit runtime secrets, logs, generated watchdog files, or alert folders. The repository contains presetup files only; runtime state belongs under `/opt/aaas` on the target host.
