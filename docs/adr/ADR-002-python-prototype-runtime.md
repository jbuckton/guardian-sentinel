# ADR-002: Python as the Prototype Runtime

**Status:** Accepted
**Date:** 2026-08-06

## Context

Decision gate G5 left the language boundary open between Python (bring-up, discovery, adapters) and Java 21 (hardened runtime). The MVP's priority is a working end-to-end edge prototype on the CM4, with rapid iteration against real Orion Jr 2 CAN data. The Linux CAN ecosystem (SocketCAN, `python-can`, `cantools`) and SQLite tooling are mature in Python.

## Decision

Both edge processes (`guardian-can` and `guardian-core`) are implemented in **Python** for the prototype/MVP.

- Target the system Python of Raspberry Pi OS Lite 64-bit (Bookworm), deployed as systemd services.
- Use `python-can` for SocketCAN, `cantools` where DBC definitions exist, and the standard-library `sqlite3` (or a thin wrapper) for persistence.
- Structure code with clear interfaces, typed models and bounded resource use so that a later port of `guardian-core` to a hardened runtime remains feasible.

A future migration of the hardened device runtime (for example to Java 21 or another platform) is a possible later decision, to be made via a new ADR once prototype behaviour, throughput and reliability data exist.

## Consequences

- Fastest path from recorded traces to a working decoder and rules engine; one language across exploration, simulation, adapters and runtime.
- Throughput and GC/latency characteristics must be validated during Phase 4 soak testing; the two-process split (ADR-003) and non-blocking ingestion rules bound the risk.
- Test tooling (trace replay, fault injection) shares the production decoder path directly.

## Alternatives considered

- **Java 21 for `guardian-core` now** — rejected for the MVP: slows iteration during protocol discovery and doubles the toolchain before the product is proven.
- **Rust/Go** — not pursued for the MVP; may be evaluated alongside any future hardening ADR.
