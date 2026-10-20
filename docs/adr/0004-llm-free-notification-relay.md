# ADR-0004: Tenant-to-operator notifications bypass LLMs

**Status:** Proposed

## Context
The original design sends tenant messages to the Hermes admin agent, which then relays them to the operator. That puts text controlled by a tenant into the context of an LLM that has platform authority, which is a direct prompt-injection path.

## Decision
- `aaas-relay`, running as `aaas` and sandboxed, listens on one unix socket per tenant at `/run/aaas/relay/<id>.sock`. Each socket is bind-mounted only into its own tenant's container, so the socket identifies the tenant.
- Messages are JSON `{level, title, body}`. Sizes are capped, control characters are stripped, and each tenant is limited by a token bucket (default 10 per hour, burst 3).
- Delivery goes straight to the operator chat through the Telegram Bot API as **plain text** (no `parse_mode`), prefixed `[tenant <id>]`. It reuses the admin bot token, read from Hermes's `.env`.
- The relay is also the transport behind `aaas notify`, which the health loop uses.

## Consequences
- The channel is one-way by construction: there is no read path back to tenants.
- The admin agents never see tenant text unless the operator pastes it in deliberately.
- Notifications keep working when the Hermes admin gateway is down.
