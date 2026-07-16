# Hermes Gateway Recovery

Use this skill whenever an AaaS watchdog alert reports the Hermes gateway
system service failed to start or is unhealthy.

For how to control the gateway unit and why the `hermes` CLI itself must
not be used, see the manage-hermes-gateway-service skill — that's the
source of truth for command mechanics; this skill only adds what's
specific to a watchdog-triggered recovery.

## Resolve the unit name

The unit for this deployment:

    __HERMES_GATEWAY_UNIT__

(also stored in __WATCHDOG_ENV_FILE__ as HERMES_GATEWAY_UNIT — if this
value ever changes, this skill file is re-resolved too, so treat this
file, not memory, as the source of truth.)

## Recover

```bash
sudo systemctl status __HERMES_GATEWAY_UNIT__
sudo systemctl restart __HERMES_GATEWAY_UNIT__
```

A scoped NOPASSWD sudoers rule for exactly these actions on this unit is
installed at /etc/sudoers.d/aaas-hermes-gateway-systemctl, so these run
non-interactively without a password prompt.

## If it still fails

- Check `__WATCHDOG_DIR__/watchdog.log` for the failure output.
- Check `journalctl -u __HERMES_GATEWAY_UNIT__` for the underlying
  systemd/service error.
- Check Docker is running (`docker info`) if Hermes's terminal backend
  depends on it.
- Do NOT reinstall Hermes or edit the wrapper/sudoers as a first response
  — those are intentional and correct; the fix is almost always in the
  gateway process itself.

## Verify Mnemosyne recovered too

Mnemosyne runs in-process inside the gateway (not a separate service), so
an active unit does not by itself confirm it re-initialized cleanly. These
are read-only checks, not gateway-control operations:

```bash
sudo -u __AAAS_USER__ __HERMES_HOME__/mnemosyne-venv/bin/mnemosyne-hermes --hermes-home __HERMES_HOME__ status
sudo -u __AAAS_USER__ hermes mnemosyne stats
```

## Report

Once recovery is confirmed (or ruled out), use the write-report skill to
report exactly what `systemctl status __HERMES_GATEWAY_UNIT__` showed and
the result of the Mnemosyne checks above.