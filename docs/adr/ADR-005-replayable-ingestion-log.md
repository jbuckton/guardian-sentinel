# ADR-005: Best-Effort Bounded Ingestion Buffer with Explicit Gaps

**Status:** Accepted
**Date:** 2026-08-06

## Context

The one hard constraint on the edge is keeping up with a high-speed CAN bus: the SocketCAN receive loop must not fall behind the bus tick rate, or frames are lost at the socket. Absolute zero-loss is a hardware/driver property, not something an in-process Python edge service can honestly guarantee. The MVP is therefore **explicitly allowed to miss data**. The requirement is not that loss never happens, but that missing data is never mistaken for healthy data (ADR-012).

## Decision

`guardian-can` keeps a **bounded RAM ring** of typed events (ADR-004), drained best-effort to IPC and to a bounded, rotated, compressed on-disk log. The receive loop does the minimum per frame — assign identity + timestamps, enqueue — and **never blocks on storage, IPC, or core**. Keeping up with the bus takes priority over retaining every frame.

### Durability tiers (MVP; each tunable later via a new ADR)

- **Tier 0 — CAN stream / telemetry: best-effort, lossy.** Under pressure, frames are dropped. No per-frame `fsync`.
- **Tier 1 — Incident evidence: best-effort pre-roll.** A RAM pre-roll of recent frames is persisted when core signals a finding; an unlucky crash at incident onset may lose it.
- **Tier 2 — Operational safety state: durable.** Active alert/incident state, acknowledgements, config, and decoder/profile version are durably written on change (ADR-006). Low-volume, rare — the one thing that must survive a reboot, because forgetting an active alarm is a safety regression.

### Gaps are flagged best-effort, not proven exact

Sequence discontinuity (ADR-004) detects most loss. Some loss cannot be exactly quantified — a dropped session tail with no following event, frames arriving while `guardian-can` is down, a simultaneous can/core restart, or a gap marker lost on the same saturated path. So the MVP:

- counts IPC-path and log-path loss separately (best-effort);
- supports **open-ended / unknown-extent** gap markers, not only exact ranges;
- treats any gap as an evidence-confidence loss that forces the health state out of `healthy` (ADR-012).

We do **not** claim every loss is exactly measured or never silent. Exhaustive gap accounting is a later hardening (a new ADR), not first-cut scope.

### Restart & replay

On a `guardian-core` restart, core resumes from a **lightweight last-seen marker** (best-effort, not a durable checkpoint) and re-reads whatever the ring still holds through the **same decoder path** — no separate replay path, so recorded traces stay valid as tests. Anything the ring no longer holds is a gap. Re-reads may re-deliver events; effects tolerate that (ADR-011), but the MVP does not depend on strict idempotency.

### Test-harness role

The envelope format and buffer replay are the Phase 2 trace library and Phase 3 adapter tests; recorded Jr 2 sessions live in `traces/`. A trace file is a deliberate durable capture, independent of Tier-0 runtime loss.

## Consequences

- Keeps up with high-speed CAN: minimal per-frame work, no frame-rate `fsync`, low eMMC wear.
- Data loss is possible and acknowledged; it degrades evidence and health (ADR-012), never masquerades as healthy.
- Far less machinery than a zero-loss design; a future lossless/durable tier is a new ADR, made additive by the envelope and identity already in place.

## Alternatives considered

- **Guaranteed zero-loss ingestion** — rejected for MVP: not honestly achievable in-process against a high-speed bus, and imposes frame-rate durability that harms eMMC life. Lossless capture belongs in a dedicated hardware/driver path, considered later.
- **Silent best-effort (no gap flags)** — rejected: loss must degrade health, never hide.
