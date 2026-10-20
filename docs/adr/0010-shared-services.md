# ADR-0010: Share everything that holds no tenant state

**Status:** Proposed

## Context
Running a full copy of every service per tenant wastes resources. For example, Mnemosyne's `embeddings` profile adds about 800 MB per tenant, which is about 38 GiB at 50 tenants. The operator wants every service shared across tenants where that's possible, and the design kept simple.

Constraints:
- Mnemosyne's remote mode (`MNEMOSYNE_EMBEDDING_API_URL`) speaks the OpenAI embeddings format, with an optional bearer token and a configured model name (verified in 3.15.1).
- Hermes speech-to-text can't be pointed at a custom endpoint.

## Decision
Rule: **share code, model files and stateless processing; never share tenant state.**

| Shared, one per host | Per tenant |
|---|---|
| Tenant image (Hermes + Mnemosyne + numpy + sqlite-vec, no fastembed) | Hermes process (container) |
| Read-only tenant skills directory | Memory DB and data directory |
| `aaas-embed`: one embeddings service | Secrets (Telegram, LLM, STT keys) |
| Notification relay; all platform services | Telegram bot |

`aaas-embed` is kept deliberately minimal:
- One pinned model, the same one Mnemosyne's `embeddings` profile uses.
- Built on Mnemosyne's own model loader, so vectors are identical to local mode.
- No auth and no quotas, to keep it simple. A concurrency limit protects the host. Per-tenant tokens are possible later because the client supports them.
- Read-only rootfs, no request logging, no cache.
- On an `internal` network with no egress, reachable only at `10.255.255.1:8800`. Tenants can connect to it; it can never connect to them.

STT is **not shared**, because Hermes can't reach a shared endpoint. It uses each tenant's own STT API key, or is unavailable for that tenant.

## Consequences
- RAM for embeddings drops from about 38 GiB to about 210 MB (measured). The image is pulled once, and skills are updated once for all tenants.
- `aaas-embed` is a shared dependency. If it is down, recall falls back to keywords and chat keeps working. Failures must be *refused*, never *dropped*: the client's fixed 30 s × 3 retries would otherwise stall tenants for minutes. It is covered by health checks and by the phase 3 isolation tests.
- Having no auth means no per-tenant usage limits on embeddings. That's acceptable because requests are small, and a concurrency cap bounds the total load.
- Changing the embedding model means re-embedding every tenant, so it is a deliberate upgrade step.
