# ADR-0009: Out-of-band confirmation for destructive actions

**Status:** Proposed

## Context
A confused or manipulated admin agent, or a hijacked operator Telegram session, could destroy tenant data. A rule in a prompt ("ask before deleting") is not an enforcement mechanism.

## Decision
Destructive verbs (`tenant.destroy`, `tenant.restore`, `platform.uninstall`) work in two steps:
1. The first call returns only a request id. `aaasd` generates a 6-digit code, valid for 10 minutes and single-use, and sends it to the operator **through the notification channel**, never in the response to the caller.
2. The action executes only on `aaas confirm <code>`.

`tenant.destroy` always takes a final encrypted backup first, and the backup is retained for 30 days.

## Consequences
- An LLM cannot approve its own destructive action. The operator has to read the code from Telegram and supply it.
- This costs one extra step per destructive action, which is rare.
