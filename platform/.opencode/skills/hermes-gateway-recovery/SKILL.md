# Hermes Gateway Recovery

Use this skill whenever an AaaS watchdog alert reports the Hermes gateway
system service failed to start or is unhealthy.

## Why the obvious command fails

The `hermes` command on PATH (/usr/local/bin/hermes) is a guard wrapper
that refuses to run for anyone except the '__AAAS_USER__' user — including
root. Running `sudo hermes gateway ...` therefore always fails with
"hermes must be run as the '__AAAS_USER__' user", even as root, because the
wrapper's own check runs first and blocks it.

Separately, --system gateway operations require root, which the
'__AAAS_USER__' user does not have on its own.

## Correct recovery procedure

1. Read `HERMES_REAL_BIN` from __CONFIG_FILE__ — this is the actual
   hermes binary path, not the wrapper.
2. Call it directly via sudo, bypassing the wrapper entirely:

```bash
source __CONFIG_FILE__
sudo "$HERMES_REAL_BIN" gateway status --system
sudo "$HERMES_REAL_BIN" gateway start --system
# or, if it's already running but unhealthy:
sudo "$HERMES_REAL_BIN" gateway restart --system
```

A scoped NOPASSWD sudoers rule for exactly "$HERMES_REAL_BIN gateway *"
is installed at /etc/sudoers.d/aaas-hermes-gateway, so these commands run
non-interactively as '__AAAS_USER__' without a password prompt.

3. If `gateway start --system` still fails after this:
   - Check `__WATCHDOG_DIR__/watchdog.log` for the failure output.
   - Check `journalctl -u $(systemctl list-unit-files --type=service --no-legend | awk '$1 ~ /hermes/ && $1 ~ /gateway/ {print $1; exit}')`
     for the underlying systemd/service error.
   - Check Docker is running (`docker info`) if Hermes's terminal backend
     depends on it.
   - Do NOT attempt to reinstall Hermes or edit the wrapper as a first
     response — the wrapper and sudoers grant are intentional and correct;
     the fix is almost always in the gateway process itself, not the
     access-control layer around it.
4. Once the gateway is confirmed running again, also verify Mnemosyne
   recovered along with it. Mnemosyne runs in-process inside the Hermes
   gateway (it is not a separate service), so a running gateway does NOT
   by itself guarantee the memory provider re-initialized cleanly:

```bash
sudo -u __AAAS_USER__ hermes plugins list | grep mnemosyne
sudo -u __AAAS_USER__ hermes mnemosyne stats
sudo -u __AAAS_USER__ hermes doctor | grep -A5 'Memory Provider'
```

5. Report back what `gateway status --system` shows after recovery, plus
   the Mnemosyne checks from step 4, and note the outcome in the alert
   file under `__ALERT_DIR__/` before removing it, so the audit trail is
   preserved.