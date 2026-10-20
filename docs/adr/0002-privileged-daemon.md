# ADR-0002: Privileged operations via a socket-activated root daemon

**Status:** Proposed

## Context
Today, root-level actions are spread across three mechanisms:
- sudoers rules, including `NOPASSWD: <aaas-writable hermes binary> gateway *`, which is effectively root
- membership in the `docker` group, which is root-equivalent
- ad-hoc `sudo` in skills

The admin agents are LLMs reachable over Telegram, and they have to be treated as manipulable. `NoNewPrivileges` sandboxing is impossible while they rely on `sudo`.

## Decision
- Add `aaasd`, a root daemon in stdlib-only Python. It is socket-activated (`aaasd.socket`, `/run/aaas/aaasd.sock`, `0660 root:aaas-admin`).
- Callers are authenticated by `SO_PEERCRED`. Only uids in `aaas-admin` are accepted.
- Requests are JSON verbs with strict schemas (regex ids, enums, size limits). There is no shell interpolation; `subprocess` always receives argument lists.
- Every call is written to journald: uid, verb, redacted arguments, result, and duration.
- No verb returns tenant data. `tenant.status` returns runtime metadata only.
- The daemon's code lives in the root-owned release tree.
- Remove every AaaS sudoers file, and remove `aaas` from the `docker` group.

## Consequences
- All admin-plane units can run with `NoNewPrivileges=yes` and `ProtectSystem=strict`.
- The whole privileged surface is one small, auditable, testable module.
- Socket activation means the daemon is not resident when idle and restarts on demand, so there is no long-lived state to corrupt.
- New capabilities need a new verb. That friction is deliberate.
