# Architecture Decision Records

Format: Context → Decision → Consequences. Status is one of Proposed, Accepted, or Superseded.

| # | Title | Status |
|---|---|---|
| [0001](0001-single-host-topology.md) | Single-host topology with a node seam | Proposed |
| [0002](0002-privileged-daemon.md) | Privileged operations via a socket-activated root daemon | Proposed |
| [0003](0003-tenant-isolation.md) | Tenant isolation: Docker userns-remap, hardened profile, per-tenant network | Proposed |
| [0004](0004-llm-free-notification-relay.md) | Tenant-to-operator notifications bypass LLMs | Proposed |
| [0005](0005-bounded-self-healing.md) | Systemd-native health loop with bounded LLM repair | Proposed |
| [0006](0006-immutable-releases.md) | Immutable versioned releases, state kept separate | Proposed |
| [0007](0007-pinned-dependencies.md) | Pinned dependencies and a platform-owned Hermes runtime | Proposed |
| [0008](0008-stack.md) | Debian/Ubuntu, bash bootstrap plus stdlib Python | Proposed |
| [0009](0009-out-of-band-confirmation.md) | Out-of-band confirmation for destructive actions | Proposed |
| [0010](0010-shared-services.md) | Share everything that holds no tenant state | Proposed |
