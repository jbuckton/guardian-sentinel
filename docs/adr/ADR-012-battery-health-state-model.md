# ADR-012: Explicit Battery Snapshot Health-State Model

**Status:** Accepted
**Date:** 2026-08-07

## Context

A core safety principle is that stale or missing data must never masquerade as a healthy battery (README; data-quality rule in the plan). ADR-010 requires every snapshot to carry quality metadata, but metadata is descriptive: on its own it does not prevent an incomplete or degraded snapshot from being *reported* as healthy by the API, MQTT uplink, or a dashboard. The gap between "we recorded that data was missing" and "we refuse to call this healthy" must be closed by an explicit state machine, not by each consumer's own interpretation of raw quality fields.

## Decision

Every assembled battery snapshot has exactly one **derived health state**, computed by `guardian-core` from the snapshot's quality metadata and the active profile (ADR-010). Consumers render this state; they never re-derive health from raw fields.

### States

- **`unknown`** — insufficient information to make any health claim (e.g. before a full broadcast cycle has been observed after startup; decoder/profile not yet loaded). The default at startup; never silently upgraded.
- **`degraded`** — the snapshot is usable but incomplete or partially stale: some non-critical inputs missing/stale, coherence below target, or reduced signal quality. Monitoring continues; the limitation is explicit.
- **`fault`** — a condition that invalidates health claims: profile/telemetry mismatch (ADR-010), a missing or stale **critical** input, decoder failure, or a stale-value invalidation on a safety-relevant signal.
- **`healthy`** — asserted **only** when all critical inputs are present and fresh for the active profile, coherence and quality meet thresholds, and no fault condition holds. Absence of evidence is never `healthy`; it is `unknown` or `degraded`.

`healthy` is the hardest state to reach by construction: it requires positive, fresh, complete evidence — not merely the absence of a raised alarm.

### Determination rules

- **Critical vs non-critical** inputs are defined per profile configuration (ADR-010), never hard-coded. Missing/stale critical input ⇒ at least `fault`; missing/stale non-critical ⇒ at least `degraded`.
- **Startup / partial broadcast cycle:** until a complete cycle of the profile's configured broadcasts has been observed, the snapshot is `unknown` (or `degraded` once partial-but-usable), never `healthy`.
- **Profile mismatch** (cell count, broadcast set, etc.) ⇒ `fault` (ADR-010).
- **Decoder failure / unknown schema version** ⇒ `fault`.
- **Stale-value invalidation:** a value past its freshness bound is treated as missing, not carried forward (data-quality rule); its criticality then drives `degraded` vs `fault`.

### Representation and recovery

- **API and MQTT** expose the state as a first-class field alongside the quality metadata that justifies it; a consumer that shows only "healthy/not" must map from this field, and Grafana (ADR-008) visualises it read-only.
- **Recovery hysteresis:** transitions *toward* `healthy` require the qualifying conditions to hold for a configured dwell time / sample count, to prevent flapping across a marginal boundary; transitions *toward* `fault` are immediate. Hysteresis parameters are profile configuration.
- The health state is an input to, but distinct from, the alert lifecycle: an alert may be raised on a `fault`, but the snapshot state exists even when no alert rule matches.

## Consequences

- "Stale/missing never looks healthy" becomes a testable invariant with a single owner, not a property each consumer must independently uphold.
- Startup, partial cycles, and decoder/profile failures have defined, conservative states rather than ambiguous ones.
- The state is evidence-linked (it cites the quality metadata behind it), supporting Phase 6 incident explanations.
- Rules, API, and uplink all depend on this enum; changing its meaning is a new ADR.

## Alternatives considered

- **Quality metadata only, each consumer decides health** — rejected: guarantees divergent, un-auditable health claims and risks a consumer calling an incomplete snapshot healthy.
- **Binary healthy/unhealthy** — rejected: collapses `unknown` (no evidence) into a claim, violating the fail-explicitly principle.
- **Deriving criticality from signal names** — rejected: criticality is a profile/installation fact, not a naming convention (consistent with ADR-010).
