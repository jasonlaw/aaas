---
name: manage-hermes-gateway-service
description: "Restart, stop, start, or check the Hermes Agent gateway service running as a systemd unit"
metadata:
  hermes:
    tags: [hermes, gateway, systemd, admin]
---
# Manage Hermes Gateway Service

**Never run `hermes gateway restart|start|stop`** — it loops regardless of
sudo. Use `systemctl` instead.

## Commands

```bash
sudo systemctl restart hermes-gateway.service   # restart
sudo systemctl stop hermes-gateway.service      # stop
sudo systemctl start hermes-gateway.service     # start
hermes gateway status                           # status — CLI is fine for this
```

`hermes gateway status` is the one subcommand that's safe and useful — use
it to check current state before acting, and to verify after any
start/stop/restart.

## After acting

Give it a few seconds to reconnect (Telegram reconnects first), then
confirm with `hermes gateway status` or by tailing `~/.hermes/logs/gateway.log`.

## Pitfalls

- **Don't use `systemctl --user`** — the unit lives at
  `/etc/systemd/system/hermes-gateway.service`, not a user-level unit.
- The service runs as `aaas` via a drop-in at
  `/etc/systemd/system/hermes-gateway.service.d/aaas.conf` — that's already
  handled by the unit; don't try to `sudo -u aaas` anything yourself.
- WSL: needs `systemd=true` in `/etc/wsl.conf` or the service won't survive
  WSL session close.