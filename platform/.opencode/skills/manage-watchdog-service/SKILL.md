---
name: manage-watchdog-service
description: Start, stop, restart, or check the status of the AaaS Hermes watchdog (aaas-watchdog.service). Use whenever the user wants to control the watchdog daemon that keeps the Hermes gateway alive, check whether it's currently running, review unresolved watchdog alerts, or restart it after changing watchdog/.env. Trigger on phrases like "start/stop/restart the watchdog", "is the watchdog running", "check watchdog status", or "watchdog alerts".
---

# Manage Watchdog Service

Controls `aaas-watchdog.service`, the systemd unit that keeps the Hermes
gateway (`hermes gateway --system`) healthy. Installed and enabled by
`install.sh`'s `install_watchdog_service()`; this skill only starts, stops,
restarts, and inspects it — it does not (re)install it.

## Important: this is not a long-running daemon

`watchdog/watchdog.sh` is single-shot: it checks the gateway unit with
`systemctl is-active`, tries one `systemctl restart` if it's down, and
exits. The unit's
`Restart=always` / `RestartSec=20` is what turns that into a ~20s polling
loop. There is no long-lived `watchdog.sh` process to `pgrep` for — checking
"is the watchdog running" means checking the *unit's* active state, not a PID.

## Paths (derived from install.sh)

- Watchdog dir: `${AAAS_ROOT:-/opt/aaas}/platform/watchdog`
- Script: `<watchdog_dir>/watchdog.sh`
- Log: `<watchdog_dir>/watchdog.log`
- Alerts: `<watchdog_dir>/alerts/alert-<timestamp>-<pid>/alert.txt`
- Incident state: `<watchdog_dir>/state/<alert_code>.incident` (open incident, repair attempts, last attempt time)
- Config sourced by watchdog.sh: `<platform_dir>/watchdog/.env` (its own file — currently just `HERMES_GATEWAY_UNIT`; separate from Hermes's `~/.hermes/.env` and from the platform's `<platform_dir>/.env`)
- systemd unit: `aaas-watchdog.service` (installed to `/etc/systemd/system/`)

## Preconditions

Before doing anything, confirm systemd is actually in play:

```bash
command -v systemctl >/dev/null 2>&1 || echo "no systemd on this host"
systemctl list-unit-files aaas-watchdog.service --no-legend 2>/dev/null
```

- If `systemctl` is missing: stop here and tell the user there is no
  watchdog service to manage. `install.sh` explicitly skips installing one
  on non-systemd hosts (`write_alert`/`install_watchdog_service` both check
  `have systemctl` and warn+return rather than falling back to a background
  loop). Manually looping `watchdog.sh` via cron is the only option, and
  that's a separate decision for the user to make — don't silently set it up.
- If the unit file isn't found: the watchdog was never installed on this
  host. Point the user at `install.sh` (`install_watchdog_service`) rather
  than trying to start a nonexistent unit.

## Operations

All state-changing operations need root/sudo, same as `install.sh`.

### Status

```bash
systemctl is-active aaas-watchdog.service
systemctl status aaas-watchdog.service --no-pager
```

Also worth checking alongside status, since the unit can be "active" while
still reporting a problem underneath:

```bash
# unresolved alerts (each is its own timestamped folder)
ls -1 "${AAAS_ROOT:-/opt/aaas}/platform/watchdog/alerts" 2>/dev/null

# recent log tail
tail -n 50 "${AAAS_ROOT:-/opt/aaas}/platform/watchdog/watchdog.log"
```

An alert folder existing under `alerts/` means the watchdog (or install.sh)
already tried to page the admin agent about a failure — surface that to the
user before declaring things healthy, even if `is-active` says yes.

### How repairs are bounded

A failure the restart can't fix opens **one** incident per `alert_code`,
tracked in `state/<alert_code>.incident`. Every cycle after that reuses it
rather than creating new folders. opencode repair runs are limited:

- at most `WATCHDOG_MAX_REPAIRS` attempts (default 3), each capped at
  `WATCHDOG_REPAIR_TIMEOUT` (default `15m`)
- spaced by `WATCHDOG_BACKOFF` seconds (default `300 1200 3600`)
- after that, the log says "waiting for a human" and no more runs happen

The budget only resets when the watchdog sees the gateway healthy again. It
then appends `resolved_utc:` to `alert.txt` and deletes the state file. To
start a fresh repair budget by hand after fixing something, delete
`state/<alert_code>.incident`.

```bash
cat "${AAAS_ROOT:-/opt/aaas}/platform/watchdog/state/"*.incident 2>/dev/null
```

### Start

```bash
sudo systemctl start aaas-watchdog.service
```

Confirm:

```bash
sudo systemctl is-active --quiet aaas-watchdog.service && echo started
```

If it fails to become active, don't retry blindly — check
`systemctl status aaas-watchdog.service --no-pager` and the log tail above
for the reason first. The usual cause is `<platform_dir>/watchdog/.env`
being missing or unreadable, or `HERMES_GATEWAY_UNIT` not being set in it.

### Stop

```bash
sudo systemctl stop aaas-watchdog.service
```

This only stops the polling unit — it does **not** stop the Hermes gateway
itself. The gateway is a separate systemd service (`hermes gateway install
--system` in `install.sh`); stopping the watchdog just means it will no
longer notice or auto-restart the gateway if it goes down.

### Restart

```bash
sudo systemctl restart aaas-watchdog.service
```

Rarely needed. `watchdog.sh` re-reads `<platform_dir>/watchdog/.env` on
every ~20s cycle, so edits take effect on the next cycle. A restart only
forces that cycle to happen now.

## What NOT to do here

- Don't call `systemctl enable`/`disable` as part of "start"/"stop" —
  enabling controls boot-time autostart, which is `install.sh`'s job
  (`install_watchdog_service`), not something implied by a start/stop
  request.
- Don't reach for `pkill -f watchdog.sh` as a "stop" mechanism. Because the
  script is single-shot, killing a mid-run process doesn't stop the
  service — systemd will just start it again at the next `RestartSec`
  interval. `systemctl stop` is the only correct way to actually halt it.
- Don't conflate this with restarting the Hermes gateway itself — that's a
  different unit, controlled with `sudo systemctl restart
  __HERMES_GATEWAY_UNIT__` (see manage-hermes-gateway-service). Never use
  `hermes gateway restart`.