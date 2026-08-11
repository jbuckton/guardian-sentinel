# Architecture Decision Records

Durable decisions for Guardian Sentinel. Each ADR records one decision, its context, and its consequences. Statuses used: **Proposed** or **Accepted**. Superseding a decision requires a new ADR; ADRs are never edited to reverse a decision silently.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [ADR-001](ADR-001-orion-jr2-first-bms.md) | Orion BMS Jr 2 as the sole initial BMS target | Accepted |
| [ADR-002](ADR-002-python-prototype-runtime.md) | Python as the prototype runtime | Accepted |
| [ADR-003](ADR-003-two-edge-processes.md) | Two edge processes: `guardian-can` and `guardian-core` | Accepted |
| [ADR-004](ADR-004-typed-ingestion-event-envelope.md) | Versioned typed ingestion-event envelope | Accepted |
| [ADR-005](ADR-005-replayable-ingestion-log.md) | Best-effort bounded ingestion buffer with explicit gaps | Accepted |
| [ADR-006](ADR-006-sqlite-edge-persistence.md) | SQLite for edge persistence, separated by concern | Accepted |
| [ADR-007](ADR-007-single-writer-per-database.md) | Single-writer ownership per SQLite database | Accepted |
| [ADR-008](ADR-008-backend-authoritative-grafana-optional.md) | Guardian backend authoritative; Grafana optional | Accepted |
| [ADR-009](ADR-009-no-actuation-mvp.md) | No actuation in the MVP | Accepted |
| [ADR-010](ADR-010-installation-profiles.md) | Installation profiles `48-10` (32 cells) and `48-20` (64 cells) | Accepted |
| [ADR-011](ADR-011-delivery-identity-idempotency.md) | Event identity, best-effort telemetry, and Tier-2 replay safety | Accepted |
| [ADR-012](ADR-012-battery-health-state-model.md) | Battery condition and data confidence as separate axes | Accepted |
| [ADR-013](ADR-013-storage-quotas-exhaustion-policy.md) | Storage quotas and exhaustion policy | Accepted |
| [ADR-014](ADR-014-local-operation-independent-of-remote-and-ai.md) | Local operation independent of remote and AI services | Accepted |

## Template

```markdown
# ADR-NNN: Title

**Status:** Proposed | Accepted
**Date:** YYYY-MM-DD

## Context
Why this decision is needed; forces at play.

## Decision
What was decided, stated imperatively.

## Consequences
What becomes easier, harder, or constrained. Follow-up obligations.

## Alternatives considered
Options rejected and why.
```
