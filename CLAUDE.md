# Guardian Sentinel

Edge-based lithium battery monitoring and assurance platform. An independent, **read-only** monitoring gateway that sits alongside a battery management system (BMS), observes it over CAN, validates and stores telemetry locally, detects abnormal and deteriorating behaviour, and delivers alerts/telemetry to a remote backend — while remaining fully functional offline.

**Repository status: documentation only.** No source code has been implemented yet. The `edge/` tree is a planned layout; each directory holds a placeholder README describing its future contents. Durable decisions live in ADRs (`docs/adr/`); the current plan is `docs/implementation-plan.md`.

## Hard constraints — do not violate

These are accepted, ADR-backed decisions. Do not work around them, and do not "helpfully" add capability beyond them. Reversing any of these requires a **new ADR**, never a silent edit.

1. **Orion BMS Jr 2 only** (ADR-001). It is the sole supported BMS for the MVP. Compatibility with the original Orion BMS Jr is **not** assumed or tested. Build exactly one adapter, `edge/guardian_core/adapters/orion_jr2/`. Do **not** create Jr/Jr2 protocol families or generation-dispatch layers.

2. **No actuation, ever, in the MVP** (ADR-009). CAN integration is strictly **read-only / listen-only** — transmit no frames intended to influence the BMS, chargers, contactors, or any equipment. No hardware control outputs. No AI/Claude tool exposes actuation; diagnostic tooling is read-only. Outputs are alerts, findings, evidence and recommendations only.

3. **Never invent message definitions** (ADR-001, ADR-010). CAN message definitions, IDs, scaling, units, and broadcast configuration must come from **Orion Jr 2 documentation and the actual deployed unit's configuration export** — never assumed, defaulted, or invented. The same applies to profile fields: do not infer chemistry, topology, thresholds, or thermistor layout from a profile name.

4. **No premature multi-BMS / multi-generation abstractions** (ADR-001). Do not introduce a vendor-neutral protocol framework, adapter interface, or generation abstraction unless required by observed Jr 2 data or a later accepted ADR. The adapter layer stays flat. A second BMS is a future ADR, not an MVP requirement.

5. **No premature microservice split** (ADR-003). Begin with exactly two edge processes. Split storage, uplink, or analysis into separate services only when testing shows a concrete need — via a new ADR.

## Governing principles

- **Safety before sophistication; read-only before control.** No actuation in the MVP.
- **Edge before cloud.** The device must remain useful and safe when disconnected.
- **Fail explicitly.** Stale or missing data must never masquerade as a healthy battery. A missing/stale cell value stays explicitly missing or stale — never carried forward as current.
- **Evidence before conclusions.** Every finding links to the telemetry behind it.

## Architecture

Two edge processes on a Raspberry Pi CM4, each a systemd service (ADR-003):

- **`guardian-can`** — SocketCAN ingestion only. Receipt timestamps (wall-clock + monotonic), sequence numbers, session identity, CAN health (error counters, state changes, bus-off, restarts), rolling bounded trace capture, bounded buffering, and forwarding typed events over IPC. Must **not** decode batteries, write to SQLite, publish MQTT, or evaluate rules.
- **`guardian-core`** — Orion Jr 2 decoding, state assembly + signal quality, deterministic observations/findings, alert/incident lifecycle, SQLite persistence, MQTT delivery, local API, device-health.

**Non-blocking rule:** the SocketCAN receive loop must never block on core, SQLite, MQTT, HTTP, dashboard, or AI services. All downstream paths use bounded queues. On overload: record lag, spool to the bounded log, mark ingestion degraded, count/expose dropped frames — **never silently lose evidence.**

**IPC** (ADR-004): Unix domain socket, MessagePack-framed, carrying a single **versioned, typed event envelope** for everything crossing the boundary (live and replay). Event types: CAN frame, CAN state change, CAN error, CAN interface restart, clock adjustment, ingestion overflow, ingestion gap, session start, session end. Ordering is **within-session by sequence, across-session best-effort by session-start time** (see *Event ordering & delivery* below). Core must **reject unknown schema versions explicitly**, never guess.

**Ingestion buffer — best-effort, tiered durability** (ADR-005): the hard constraint is **keeping up with a high-speed CAN bus** — the receive loop does the minimum per frame and **never blocks** on storage/IPC/core. The MVP is **explicitly allowed to miss data**; the rule is that missing data never reads as healthy (ADR-012), not that loss never happens. `guardian-can` keeps a bounded RAM ring drained best-effort to IPC and a bounded, rotated, compressed on-disk log — **no per-frame `fsync`**. Tiers: **Tier 0** CAN stream/telemetry = best-effort, lossy (loss flagged where detectable, but **not** claimed exact); **Tier 1** incident evidence = RAM **pre-roll** persisted on trigger (best-effort); **Tier 2** operational safety state (active alert/incident, acks, config, decoder/profile version) = **durable on change** (KB, rare — the one thing that must survive a reboot). On a `guardian-core` restart, core resumes from a **lightweight last-seen marker** and re-reads what the ring still holds through the **same decoder path** (no separate replay path); anything gone is a gap. A lossless/durable tier is a **future ADR**, made additive by the envelope + identity already present. This buffer *is* the test harness; recorded Jr 2 sessions live in `traces/`. Raw CAN frames are **never** synchronously inserted into SQLite.

**Event ordering & delivery** (ADR-004, ADR-011): a session's identity is a **collision-resistant session id** (UUID or `boot_id`+nonce) allocated at session start — identity, not an ordering counter (no fragile durable generation). Order **within** a session is by per-session sequence number; **across** sessions is **best-effort by session-start time** (monotonic within a boot; wall-clock, at its confidence, across boots) — approximate cross-session ordering is accepted. Wall-clock carries a confidence qualifier (`unsynchronised`/`synchronised`/`stepped`); receipt time ≠ physical-event time. **Idempotency is best-effort first cut** (ADR-011), not a strict guarantee: dedup where cheap and visibly-wrong-otherwise (uplink token; alert transitions applied against current state), tolerate occasional duplicate telemetry. Nothing safety-relevant depends on strict idempotency; an event may also be delivered **zero** times (a gap). Tightening idempotency and adding durable resume are a later ADR.

**Persistence** (ADR-006, ADR-007, ADR-013): SQLite, WAL mode, **two separate database files** (not one file with multiple writers). **Operational** DB (config, versions, alerts, incidents, findings, outbound delivery state, lightweight last-seen marker, evidence-pin references, device-health) vs **telemetry** DB (normalised telemetry + observations, batched/downsampled). **Single owning writer per database file** — all other components, including MQTT delivery-state updates, submit through the owner's bounded queue; no independent writers. Durability is tiered (ADR-005/006): telemetry best-effort/batched (`synchronous=NORMAL`), operational safety state durable on change (`FULL`); the MVP **avoids per-frame `fsync`** and defers group-commit/endurance tuning to Phase 4. Every storage consumer (log, pinned evidence, both DBs, MQTT backlog) has a **hard quota**; a **reserve** is held that only *current* operational safety state and alert uplinks may use. Exhaustion evicts in a fixed safety order (telemetry → routine log tail → closed-incident evidence → low-priority backlog) with recorded eviction/gap events. History is kept bounded by **compaction** (closed incidents → summaries, superseded transitions collapsed, acked items eligible) so the current-safety working set fits the reserve; the "never evicted" guarantee holds for that bounded set, and in the extreme terminal case loss is explicit, prioritised, and alertable — never a silent stall (ADR-013). Ingestion never stalls for storage.

**Health state model** (ADR-012): every assembled snapshot resolves to exactly one derived state — `unknown` / `degraded` / `fault` / `healthy` — computed by core; consumers render it, never re-derive it. **`healthy` requires complete, fresh critical inputs** (criticality is per-profile config); startup/partial cycles are `unknown`, profile mismatch or decoder failure is `fault`. Quality metadata alone must never let an incomplete snapshot be reported healthy. A separate **data-confidence axis** distinguishes "battery looks bad" from "we can't currently see the battery": any ingestion gap immediately invalidates `healthy`, a critical/prolonged gap forces `fault`, and recovery needs a fresh broadcast cycle plus dwell. Transitions toward `healthy` use hysteresis; toward `fault` are immediate.

**Backend & local independence** (ADR-008, ADR-014): Guardian's own backend is the **authoritative system of record** (device registry, ingestion, storage, alert/incident lifecycle, acknowledgement, config, audit). **Grafana is optional visualisation only.** Crucially, **local safety function depends on no remote or AI service**: the device must reach full local function from cold boot with DNS, MQTT, backend, Grafana, and AI all unreachable, indefinitely. AI/Claude is strictly advisory and read-only — its failure or absence must never affect findings, alerts, or health state. There is a distinct **offline-first local acceptance gate** that must pass before the remote/Claude parts of the demo.

**Installation profiles** (ADR-010): `48-10` (expected 32 cells) and `48-20` (expected 64 cells) — **cell counts are provisional** until confirmed from the actual unit's Orion Jr 2 configuration export. Names are labels only — never a source of technical truth. Each profile explicitly defines Jr 2 firmware version, chemistry, cell count, topology, capacity, current-sensor config, thermistor count/placement, charger limits, CAN config, and configured broadcasts, populated from real unit data and citing the export it came from. Profile/telemetry mismatch (e.g. cell count) is a **loud, explicit fault** — never silently reconciled.

## Stack

- **Language:** Python for both processes in the MVP (ADR-002). Target Raspberry Pi OS Lite 64-bit (Bookworm) system Python, deployed as systemd services. Use `python-can` (SocketCAN), `cantools` where DBC exists, stdlib `sqlite3`. Keep interfaces/typed models/bounded resource use clean so a later hardened-runtime port stays feasible.
- **Compute:** Raspberry Pi CM4 (4 GB / 16 GB eMMC); Waveshare CM4 PoE 4G carrier; SIM7600X-H-M2.
- **CAN:** SocketCAN, can-utils, python-can, cantools; isolated, listen-only interface.
- **Telemetry:** MQTT 5 over TLS, store-and-forward → Guardian backend.
- **Dev networking:** Tailscale/WireGuard.

## Planned layout

```
edge/
  guardian_can/                        # SocketCAN ingestion process
  guardian_core/                       # decoding, state, rules, persistence, uplink, local API
    adapters/orion_jr2/                # sole MVP adapter
      decoder.py  profile.py  validation.py  messages.py
profiles/                              # installation profiles 48-10, 48-20 (versioned config)
traces/                               # versioned CAN trace library (ingestion-log format, replayable)
docs/
  implementation-plan.md              # phased plan, decision gates G1–G7
  adr/                                # ADR-001 … ADR-010 + index
```

## Phases (see `docs/implementation-plan.md`)

1. Hardware bring-up (incl. CAN hardware selection G4, clock discipline baseline)
2. CAN capture — record Jr 2 sessions directly in ingestion-log format; catalogue every CAN ID against docs + config export
3. Orion Jr 2 adapter + normalised model + profile validation + health-state derivation (ADR-012); replay-driven tests
4. Local runtime — two processes under systemd, best-effort restart/resume from last-seen marker + best-effort idempotency (ADR-011), typed-event handling, clock correction, two-file single-writer SQLite (durable Tier-2 safety state), storage quotas/reserve (ADR-013), deterministic rules, alert lifecycle, data-confidence/health (ADR-012), local API; **offline-first local acceptance gate (ADR-014) passes here** (**heaviest new scope**)
5. Remote telemetry + authoritative backend; Grafana optional; offline/reconnect + duplicate-safe upload testing
6. Diagnostic intelligence — derived metrics, evidence-linked findings, Claude-assisted **read-only, advisory** incident summaries (every conclusion cites evidence; AI failure never affects findings/alerts — ADR-014)
7. Controlled outputs — **deferred entirely (ADR-009);** requires a new ADR + safety model first

**Deterministic MVP rules** (thresholds are per-profile configuration, never hard-coded): cell over/undervoltage, high temp, temp-rise rate, cell delta/imbalance, pack overcurrent, missing critical message, invalid value, CAN bus-off, storage nearly full, connectivity lost.

## Resolved vs open decision gates

Resolved: G3 (Orion Jr 2, ADR-001), G5 (Python, ADR-002), G7 (backend authoritative / Grafana optional, ADR-008). Still open: G1 (marketing cell-sensing claims must be reconciled to the monitoring-only MVP), G2 (first pilot industry), G4 (isolated listen-only CAN hardware), G6 (cloud provider + MQTT broker — broker must not become the system of record).

## Working conventions

- Durable decisions are recorded as ADRs (`docs/adr/`), status **Proposed** or **Accepted**. Never edit an ADR to reverse a decision — supersede it with a new ADR.
- When adding an adapter module, profile field, or message definition, cite the Orion Jr 2 documentation or the unit's configuration export it came from. If a value isn't sourced from real unit data, it doesn't go in.
