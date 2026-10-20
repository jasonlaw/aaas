# ADR-0008: Debian/Ubuntu, bash bootstrap plus stdlib Python

**Status:** Proposed

## Context
The 1,700-line `install.sh` embeds Python heredocs, supports many package managers, and has no tests. Reliability comes from narrowing the supported surface and making logic testable.

## Decision
- Supported hosts: Debian 12, Ubuntu 22.04, and Ubuntu 24.04, on amd64 and arm64.
- `install.sh` is reduced to a roughly 150-line bootstrap: check the OS, install prerequisites, verify the release, and hand off.
- All logic moves into the `aaas` Python package, which uses **only the standard library**, so root code has no third-party dependencies. PyYAML is used only by `config_merge`, which runs unprivileged as `aaas`.
- CI runs shellcheck, ruff, pytest, and full installs in systemd-enabled Debian and Ubuntu containers.

## Consequences
- Every step is unit-testable and can be probed for idempotence.
- Other distributions are no longer supported, and the installer fails fast with a clear message on them.
