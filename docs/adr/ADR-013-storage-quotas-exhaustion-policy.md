# ADR-013: Storage Quotas and Exhaustion Policy

**Status:** Accepted
**Date:** 2026-08-07

## Context

The device has a finite 16 GB eMMC and must run unattended and offline for extended periods. Four consumers compete for that space: the bounded ingestion log (ADR-005), pinned incident evidence (ADR-005), the two SQLite databases with their retention tiers (ADR-006), and the outbound MQTT backlog during an outage (ADR-008). ADR-005 already calls storage exhaustion "itself a safety-relevant failure," but no ADR yet defines the quotas or what happens when they are hit. Undefined exhaustion behaviour means an offline outage or an incident burst could silently starve safety-relevant state — the exact failure the product exists to prevent.

## Decision

Each storage consumer has a **hard, explicit quota**, and total quotas plus a reserve fit within a configured device storage budget strictly smaller than the physical partition. No consumer may grow past its quota by borrowing another's space.

### Quotas (all configuration, tuned in Phase 4)

- **Ingestion log** — size- and/or time-bounded; rotates and evicts oldest-first within its quota (ADR-005).
- **Pinned evidence** — a bounded budget *carved from within* the ingestion-log quota, not additional to it, so pinning can never grow the log without bound (ADR-005 eviction rules apply).
- **Telemetry DB** — bounded by retention + downsample tiers (ADR-006); oldest, most-downsampled data evicted first.
- **Operational DB** — bounded, but see reserved capacity below; it is evicted last and least.
- **Outbound MQTT backlog** — bounded queue with priority (alerts first) and throttling (ADR-008); when full, lowest-priority telemetry is dropped from the backlog before any alert/finding.

### Reserved capacity for safety-relevant state

- A **reserve** is held that only the operational DB and the outbound alert/finding queue may consume. Telemetry, observations, and routine log data may never encroach on it.
- Under global pressure the eviction order is fixed and safety-ordered: (1) oldest downsampled telemetry, (2) routine (unpinned) ingestion-log tail, (3) closed-incident pinned evidence, (4) low-priority outbound backlog — and **never** *current* operational safety state (open findings, live alert/incident state, checkpoints, config) or queued alert uplinks, which live in the reserve.

### Compaction keeps protected state bounded

"Never evicted" is only honest if the protected set is itself **bounded**; unbounded accumulation of history cannot coexist with a finite device and indefinite operation. Protected state is therefore kept bounded by **compaction**, distinct from eviction — compaction preserves the current safety truth while discarding redundant history:

- **Closed incidents** are retained in full for a configured window, then **compacted to a durable summary** (outcome, peak values, evidence references, timestamps); their bulk pinned evidence (ADR-005) becomes eligible for eviction once compacted.
- **Superseded alert transitions** collapse to the alert's current state plus a bounded transition history (first occurrence always preserved); older intermediate transitions are compacted away.
- **Acknowledged** alerts/incidents become eligible for compaction once acknowledgement is durably recorded (and, if acknowledgement happened remotely, once that ack is confirmed delivered locally).
- **Undelivered uplinks** are bounded per priority: within the alert/finding class the queue coalesces duplicates by idempotency token (ADR-011) and retains newest-per-entity; it does not grow without bound while offline.

This makes the *current* safety state a bounded working set that fits within the reserve, while history degrades gracefully rather than growing until it collides with the bound.

### Exhaustion behaviour and terminal state

- Approaching any quota raises a **device-health observation** and, past a configured threshold, an alert — storage pressure is itself a monitored condition, not a surprise.
- Eviction of any evidence (log tail or pinned range) emits the corresponding ingestion-gap/eviction event (ADR-004/005) so loss is recorded, ordered, and alertable — never silent.
- If pressure reaches the reserve, the device enters a declared **degraded-persistence** state (surfaced in device-health and reflected in ADR-012 reporting): it keeps ingesting and detecting, keeps current safety state durable, runs compaction aggressively, and sheds the lowest-value data first; it never stalls ingestion (ADR-003) and never drops a finding or alert transition to free space for telemetry.
- **Terminal case — reserve full of only protected, non-compactable records** (e.g. many simultaneous *unacknowledged, open* incidents plus undelivered *critical* uplinks): the guarantee "current safety state is never evicted" is preserved for as long as that set fits the reserve. When it cannot, the device does **not** stall ingestion and does **not** silently drop safety state. It:
  1. raises a top-priority **persistence-saturated** alert (itself reserved space, pre-allocated so it can always be raised),
  2. stops accepting new low-priority persistence entirely,
  3. and only if the reserved safety set still cannot be admitted, sheds the **oldest, lowest-priority within the protected class** (e.g. an oldest already-summarised closed-incident record, or an oldest low-criticality undelivered uplink) with an **explicit, recorded, alertable** loss event — because an honest, ordered, logged loss of the least-critical protected record is safer than a silent stall or an arbitrary failure.
  This bounds the promise precisely: **indefinite operation is guaranteed for the bounded current-safety working set; beyond it, loss is explicit, prioritised, and never silent.** Reserve size is provisioned in Phase 4 against the worst-case concurrent-open-incident count so the terminal case is reached only under genuinely extreme, alerted conditions.
- Writes of current safety state must not fail for lack of space while any lower-priority or compactable data remains reclaimable; the writer reclaims (compact, then evict in order) before ever failing such a write.

## Consequences

- A long offline outage or an incident storm degrades predictably: telemetry resolution and replay depth shrink first, then incident *history* compacts; the current-safety working set and alert uplinks survive within a bounded, provisioned reserve, and any loss beyond that bound is explicit and prioritised — never silent, never a stall.
- The competing consumers have a single arbitration policy instead of racing for free space.
- Quotas + reserve size are named Phase 4 tuning tasks against eMMC endurance and required replay/evidence depth; they are configuration, so field tuning needs no code change.
- Provides the concrete bounds ADR-005 (log), ADR-006 (DB retention), and ADR-008 (backlog) each referred to without specifying.

## Alternatives considered

- **Rely on the filesystem / let writes fail at disk-full** — rejected: failure lands wherever the next write happens, often on safety-relevant state, and is effectively silent.
- **Single shared pool, first-come-first-served** — rejected: telemetry bursts or a large pin can starve operational state; contradicts the fail-explicitly principle.
- **Unbounded any consumer** — rejected (consistent with ADR-005): bounded behaviour is a safety property.
