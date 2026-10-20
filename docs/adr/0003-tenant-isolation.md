# ADR-0003: Tenant isolation

**Status:** Proposed

## Context
Tenants control an LLM agent that can run shell commands inside its container, so container code must be treated as hostile. Alternatives considered:
- **Rootless Docker per tenant:** strongest, but 50 daemons is a heavy operational cost.
- **gVisor or Kata:** strong, but adds a heavy dependency and has compatibility risk with Hermes tooling.
- **Podman with Quadlets:** good systemd integration, but Docker is already the chosen runtime.

## Decision
Use rootful Docker with a daemon-wide hardened configuration:
- `daemon.json`: `userns-remap: default`, `icc: false`, `no-new-privileges: true`, `live-restore: true`, `log-driver: local` with size caps, `default-address-pools`.
- Each container: `--cap-drop=ALL`, default seccomp, `--read-only` plus `tmpfs /tmp`, memory, CPU and pids limits, no Docker socket, no host mounts except its own data directory, its relay socket, and the shared read-only skills directory.
- One bridge network per tenant.
- nftables rules owned by `aaasd` drop tenant-subnet traffic to the host, RFC1918, `169.254.0.0/16`, and other tenant subnets. Public egress is allowed, because LLM and Telegram endpoints vary.
- Data directory: `/var/lib/aaas/tenants/<id>/data`, mode `0700`, owned by the remapped uid.

## Consequences
- Escaping a container lands on an unprivileged host uid that has no access to other tenants' data.
- gVisor can still be added later as a runtime option (`--runtime=runsc`) with no other change.
- Egress is not filtered by domain, so a compromised tenant can still reach the internet. That is acceptable, since it is the tenant's own agent.
