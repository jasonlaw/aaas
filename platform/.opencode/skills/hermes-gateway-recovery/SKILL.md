# Hermes Gateway Recovery

Use this skill whenever an AaaS watchdog alert reports the Hermes gateway
system service failed to start or is unhealthy.

## Why the obvious `hermes` commands don't work

The `hermes` command on PATH (/usr/local/bin/hermes) is a guard wrapper
that refuses to run for anyone except the '__AAAS_USER__' user — including
root. Separately, --system gateway operations (restart, start, stop)
require root to control the systemd unit. A single process can never
satisfy both of these at once, which produces a real, reproducible
ping-pong no matter how you invoke it:

- `hermes gateway restart` -> blocked (you aren't '__AAAS_USER__')
- `sudo hermes gateway restart` -> still blocked by the wrapper (root isn't '__AAAS_USER__')
- `sudo -u __AAAS_USER__ hermes gateway restart` -> passes the wrapper, but
  '__AAAS_USER__' isn't root, so the systemd-control step itself then fails
  needing root

This is not a transient bug — do not keep retrying different `hermes`
invocations expecting one of them to work.

## Correct recovery procedure: use systemctl, not the hermes CLI

1. Read `HERMES_GATEWAY_UNIT` from __CONFIG_FILE__ — this is the exact
   systemd unit name `hermes gateway install --system` generated.
2. Control it directly via systemctl. The unit's own `User=__AAAS_USER__`
   directive execs the process correctly at the OS level, never touching
   the wrapper or the hermes CLI's own logic at all:

```bash
source __CONFIG_FILE__
sudo systemctl status "$HERMES_GATEWAY_UNIT"
sudo systemctl restart "$HERMES_GATEWAY_UNIT"
```

A scoped NOPASSWD sudoers rule for exactly these actions on this unit is
installed at /etc/sudoers.d/aaas-hermes-gateway-systemctl, so these
commands run non-interactively as '__AAAS_USER__' without a password
prompt.

3. If the restart still fails after this:
   - Check `__WATCHDOG_DIR__/watchdog.log` for the failure output.
   - Check `journalctl -u "$HERMES_GATEWAY_UNIT"` for the underlying
     systemd/service error.
   - Check Docker is running (`docker info`) if Hermes's terminal backend
     depends on it.
   - Do NOT attempt to reinstall Hermes or edit the wrapper as a first
     response — the wrapper and sudoers grants are intentional and
     correct; the fix is almost always in the gateway process itself, not
     the access-control layer around it.
4. Once the unit is confirmed active (`systemctl is-active
   "$HERMES_GATEWAY_UNIT"`), also verify Mnemosyne recovered along with
   it. Mnemosyne runs in-process inside the Hermes gateway (it is not a
   separate service), so a running unit does NOT by itself guarantee the
   memory provider re-initialized cleanly. These read-only checks are
   fine to run as-is — they aren't gateway-control operations, so the
   wrapper-vs-root conflict above doesn't apply to them:

```bash
sudo -u __AAAS_USER__ __HERMES_HOME__/mnemosyne-venv/bin/mnemosyne-hermes --hermes-home __HERMES_HOME__ status
sudo -u __AAAS_USER__ hermes mnemosyne stats
```

5. Report back what `systemctl status "$HERMES_GATEWAY_UNIT"` shows after
   recovery, plus the Mnemosyne checks from step 4, and note the outcome
   in the alert file under `__ALERT_DIR__/` before removing it, so the
   audit trail is preserved.