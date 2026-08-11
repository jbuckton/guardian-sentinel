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
- **Tier 2 — Operational safety state: durable + replay-safe.** Active alert/incident state, acknowledgements, config, and decoder/profile version are durably written on change (ADR-006), and Tier-2 transitions carry a **deterministic effect identity** so a restart re-delivery is deduped atomically by the operational writer (ADR-007/011). Low-volume, rare — the one thing that must survive a reboot, because forgetting an active alarm is a safety regression.

### The loss contract (one wording across all documents)

**Known or inferred loss degrades data-confidence and can never appear healthy; some loss may remain undetectable in the MVP — an accepted limitation, not a claim of completeness.**

- **Known** loss: a sequence discontinuity (ADR-004) or a queue/log drop counter.
- **Inferred** loss: `guardian-core` expects the profile's configured broadcasts at their cadence, so silence past a configured interval or an incomplete session is inferred as a gap even without a discontinuity (ADR-003/012).
- **Undetectable** loss: e.g. a dropped session tail with nothing after it, or a gap marker lost on the same saturated path — cannot be seen at the time.

The MVP counts IPC-path and log-path loss separately, supports **open-ended / unknown-extent** gap markers, and treats every known or inferred gap as a data-confidence loss (ADR-012). It does **not** claim every lost frame is detected. Exhaustive gap accounting is a later hardening (a new ADR).

### Restart & replay

On a `guardian-core` restart, core resumes from a **lightweight last-seen marker** (best-effort, not a durable checkpoint) and re-reads whatever the ring still holds through the **same decoder path** — no separate replay path, so recorded traces stay valid as tests. Data the ring no longer holds is lost; where that loss is known or inferred it becomes a gap that degrades data-confidence, and some may remain undetectable (per the loss contract above). Re-reads may re-deliver events: **Tier-2 safety effects are deduped by deterministic identity and safety outputs are gated until core converges to live** (ADR-011), so replay cannot duplicate a finding or transiently clear an active incident; Tier-0 telemetry duplicates are tolerated.

### Test-harness role

The envelope format and buffer replay are the Phase 2 trace library and Phase 3 adapter tests; recorded Jr 2 sessions live in `traces/`. A trace file is a deliberate durable capture, independent of Tier-0 runtime loss.

## Consequences

- Keeps up with high-speed CAN: minimal per-frame work, no frame-rate `fsync`, low eMMC wear.
- Data loss is possible and acknowledged; known or inferred loss degrades data-confidence and never masquerades as healthy, while some loss may remain undetectable (the loss contract above).
- Far less machinery than a zero-loss design; a future lossless/durable tier is a new ADR, made additive by the envelope and identity already in place.

## Alternatives considered

- **Guaranteed zero-loss ingestion** — rejected for MVP: not honestly achievable in-process against a high-speed bus, and imposes frame-rate durability that harms eMMC life. Lossless capture belongs in a dedicated hardware/driver path, considered later.
- **Silent best-effort (no gap flags)** — rejected: known and inferred loss must degrade data-confidence, not pass as healthy.
