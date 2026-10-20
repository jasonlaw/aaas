# ADR-0001: Single-host topology with a node seam

**Status:** Proposed

## Context
The target is at most 50 tenants run by one operator. A multi-host control plane (scheduler, central registry, remote node agents) would add distributed-systems failure modes that this scale does not need.

## Decision
Everything runs on one host. Everything that touches the container runtime goes through one internal interface, `tenants.driver`, with operations `create/start/stop/status/destroy`. `aaasd` calls the interface and never calls Docker directly from its verbs.

## Consequences
- One host means one failure domain. It is mitigated by encrypted off-host backups (phase 4) and a fast, reproducible reinstall.
- Adding hosts later means adding a remote driver and a registry field `node`, not redesigning the system.
