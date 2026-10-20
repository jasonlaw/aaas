# ADR-0006: Immutable versioned releases, state kept separate

**Status:** Proposed

## Context
Today, `/opt/aaas/platform` mixes shipped files with runtime state (`.env`, logs, alerts, reports) and is rewritten in place (placeholder `sed`, untar over the old tree). As a result:
- Files deleted from the repo are never removed from hosts.
- A host cannot be diffed against a release.
- There is no rollback.

## Decision
- Releases unpack to `/opt/aaas/releases/<ver>` (root, read-only), and `/opt/aaas/current` is a symlink to the active one.
- Settings go in `/etc/aaas`, state in `/var/lib/aaas`, and logs in journald.
- Upgrade sequence: verify, unpack, run migrations, flip the symlink atomically, run health checks, and roll back automatically on failure.
- Keep the last 3 releases.
- Fixed paths following the FHS replace the `__PLACEHOLDER__` system. Runtime values are read with `aaas config get`, never baked into files.

## Consequences
- Upgrades are atomic and can be reverted, and the release tree can be verified against its checksum.
- Existing 0.1.x hosts need a one-time migration (phase 2) that moves `.hermes`, reports and watchdog state into the new layout.
