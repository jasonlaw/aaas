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

The Hermes gateway systemd unit on this deployment is:

    __HERMES_GATEWAY_UNIT__

(also stored in __WATCHDOG_ENV_FILE__ as HERMES_GATEWAY_UNIT, in case install.sh
is rerun and regenerates this value — if so, this skill file gets
re-resolved too, so treat this file, not memory, as the source of truth).

Control it directly via systemctl. The unit's own `User=__AAAS_USER__`
directive execs the process correctly at the OS level, never touching the
wrapper or the hermes CLI's own logic at all:

```bash
sudo systemctl status __HERMES_GATEWAY_UNIT__
sudo systemctl restart __HERMES_GATEWAY_UNIT__
```

A scoped NOPASSWD sudoers rule for exactly these actions on this unit is
installed at /etc/sudoers.d/aaas-hermes-gateway-systemctl, so these
commands run non-interactively as '__AAAS_USER__' without a password
prompt.

If the restart still fails after this:
- Check `__WATCHDOG_DIR__/watchdog.log` for the failure output.
- Check `journalctl -u __HERMES_GATEWAY_UNIT__` for the underlying
  systemd/service error.
- Check Docker is running (`docker info`) if Hermes's terminal backend
  depends on it.
- Do NOT attempt to reinstall Hermes or edit the wrapper as a first
  response — the wrapper and sudoers grants are intentional and correct;
  the fix is almost always in the gateway process itself, not the
  access-control layer around it.

Once the unit is confirmed active (`systemctl is-active
__HERMES_GATEWAY_UNIT__`), also verify Mnemosyne recovered along with it.
Mnemosyne runs in-process inside the Hermes gateway (it is not a separate
service), so a running unit does NOT by itself guarantee the memory
provider re-initialized cleanly. These read-only checks are fine to run
as-is — they aren't gateway-control operations, so the wrapper-vs-root
conflict above doesn't apply to them:

```bash
sudo -u __AAAS_USER__ __HERMES_HOME__/mnemosyne-venv/bin/mnemosyne-hermes --hermes-home __HERMES_HOME__ status
sudo -u __AAAS_USER__ hermes mnemosyne stats
```

Once recovery is confirmed (or ruled out), use write-report skill to report back exactly what
`systemctl status __HERMES_GATEWAY_UNIT__` showed and the result of the
Mnemosyne checks above.