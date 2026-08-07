# ADR-014: Local Operation Independent of Remote and AI Services

**Status:** Accepted
**Date:** 2026-08-07

## Context

"Edge before cloud: the device must remain useful and safe when disconnected" is a governing principle, and ADR-008 makes the backend the authoritative *system of record*. But the implementation plan's Definition of Done couples the end-to-end demo to remote delivery and a Claude-generated summary, which risks implying those are required for the device to do its safety-relevant job. They are not. The remote backend, MQTT broker, DNS, Grafana, and any AI/Claude tooling are all **non-authoritative for local safety function** and any of them can be absent — from boot, indefinitely — without degrading local detection, persistence, or operator visibility. This must be a stated, tested decision, not an assumption.

## Decision

Local safety function — decoding, snapshot health-state (ADR-012), deterministic rules, findings, alert/incident lifecycle, persistence (ADR-006/007), evidence capture and pinning (ADR-005), device-health, and the local API/status page — depends on **no remote or AI service**.

- The device must reach full local function **from a cold boot with DNS, the MQTT broker, the backend, Grafana, and all AI/Claude services unreachable**, and remain there indefinitely.
- Remote services are consumers/records downstream of local truth (ADR-008); their unavailability changes only what is *uploaded/visualised later*, never what is *detected, decided, or stored* locally.
- **AI/Claude tooling is strictly advisory and read-only (ADR-009).** Its output is explanation over already-captured evidence. AI failure, timeout, or absence must never affect findings, alert state, health state, or any stored record. No finding or alert may depend on an AI call.
- When remote is unreachable, outbound data is stored-and-forwarded within bounded backlog and reserve (ADR-013) and uploaded, duplicate-safe, on reconnection (ADR-011). Loss beyond retention bounds is explicit and alertable, never silent.
- The local API/status page presents current health state, active alerts/incidents, and device-health **without** contacting any remote service, so an operator on-site sees the truth during a total comms outage.

### Acceptance (offline-first local gate)

A local acceptance gate, distinct from the full end-to-end demo, is exercised with DNS, MQTT, backend, Grafana, and AI **unavailable from boot**. It must prove:

- local detection: every MVP rule fires and clears under replay/fault injection with no network;
- persistence: findings, alert transitions, incidents, checkpoint, and pinned evidence are durable across power loss with no network;
- operator visibility: the local API/status page shows health state and active incidents offline;
- bounded resource isolation: backlog and storage stay within quotas/reserve (ADR-013); a slow/failed AI or uplink path never blocks ingestion (ADR-003) or alters findings;
- later recovery: on reconnection, buffered data uploads duplicate-safe (ADR-011) with no loss within retention bounds.

This gate passes **before** the remote/Claude portions of the Definition of Done are exercised.

## Consequences

- The product's safety claim stands on the device alone; the cloud adds fleet visibility and convenience, not local correctness.
- Testing gains an explicit offline gate that must be green independently of Phase 5/6 remote and AI work.
- AI features (Phase 6) can be developed and can fail freely without safety consequence, because they are architecturally downstream of all decisions.
- Reinforces ADR-008 (backend authoritative as *record*, not as *controller*) and ADR-009 (no actuation; AI read-only).

## Alternatives considered

- **Treat the end-to-end demo (incl. remote + Claude) as the only acceptance gate** — rejected: it would let a remote or AI dependency creep into the local safety path undetected.
- **Allow AI to influence findings when available** — rejected: makes safety-relevant output non-deterministic and dependent on an external service (contradicts ADR-009 and the evidence-before-conclusions principle).
