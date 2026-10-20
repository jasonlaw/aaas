# ADR-0007: Pinned dependencies and a platform-owned Hermes runtime

**Status:** Proposed

## Context
`install.sh` currently:
- tracks `master`
- installs whatever version the Hermes installer and npm (`opencode-ai`) serve at the time
- lets `hermes gateway install --system` generate a unit whose name has to be discovered afterwards
- patches Hermes internals: numpy compatibility, Mnemosyne sys.path priority, and venv Python matching

Every upstream release can break a fresh install.

## Decision
- `versions.lock` pins Hermes, Mnemosyne, opencode-ai, the Node.js major and exact version, docker-ce, and the tenant base image digest. Downloads are verified against checksums.
- Hermes and Mnemosyne are installed into **one** venv that the platform owns, using a constraints file. The workarounds are deleted.
- The admin gateway runs under **our own** unit, `aaas-admin-gateway.service`, which has a fixed name and hardening directives.
- The bootstrap URL is always a release tag.
- Dependency bumps are deliberate PRs, gated by CI.

## Consequences
- Installs are reproducible.
- Upstream fixes are adopted by bumping the lock file, which takes a little manual effort.
- Depends on open question 1: whether Hermes can be installed at a pinned version.
