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

**IPC** (ADR-004): Unix domain socket, MessagePack-framed, carrying a single **versioned, typed event envelope** for everything crossing the boundary (live and replay). Event types: CAN frame, CAN state change, CAN error, CAN interface restart, clock adjustment, ingestion overflow, ingestion gap. Strictly ordered by session ID + sequence number (assigned at ingestion). Core must **reject unknown schema versions explicitly**, never guess.

**Replayable ingestion log** (ADR-005): `guardian-can` keeps a bounded, rotated, compressed log of typed events — a **first-class replay source**, not an archive. Core checkpoints its processed (session, sequence) durably; on restart it requests events after the checkpoint, `guardian-can` replays them, then core goes live. Expired ranges produce explicit **ingestion-gap events**. **Replay and live share one decoder path — no separate replay code path is permitted.** This log *is* the test harness; recorded Jr 2 sessions live in `traces/` in this format. Raw CAN frames are **never** synchronously inserted into SQLite.

**Persistence** (ADR-006, ADR-007): SQLite, WAL mode. Separate **operational** DB (config, versions, alerts, incidents, findings, outbound delivery state, replay checkpoint, device-health) from **telemetry** DB (normalised telemetry + observations, batched/downsampled, bounded retention). **Single owning writer per database** — all other components, including MQTT delivery-state updates, submit through the owner's bounded queue; no independent writers. Batched writes for telemetry; immediate durable writes for findings, alert transitions, bus-off, and config changes.

**Backend** (ADR-008): Guardian's own backend is the **authoritative system of record** (device registry, ingestion, storage, alert/incident lifecycle, acknowledgement, config, audit). **Grafana is optional visualisation only** — no alerting, incident state, acknowledgement, or config may live in it; removing it must remove nothing but convenience dashboards.

**Installation profiles** (ADR-010): `48-10` (expected 32 cells) and `48-20` (expected 64 cells). Names are labels only — never a source of technical truth. Each profile explicitly defines Jr 2 firmware version, chemistry, cell count, topology, capacity, current-sensor config, thermistor count/placement, charger limits, CAN config, and configured broadcasts, populated from real unit data. Profile/telemetry mismatch (e.g. cell count) is a **loud, explicit fault** — never silently reconciled. Every assembled snapshot records expected cell count, fresh-cell count, missing/stale indices, coherence, quality, and source/decoder version.

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
3. Orion Jr 2 adapter + normalised model + profile validation; replay-driven tests
4. Local runtime — two processes under systemd, restart/replay, typed-event handling, clock correction, single-writer SQLite, deterministic rules, alert lifecycle, local API (**heaviest new scope**)
5. Remote telemetry + authoritative backend; Grafana optional; offline/reconnect testing
6. Diagnostic intelligence — derived metrics, evidence-linked findings, Claude-assisted **read-only** incident summaries (every conclusion cites evidence)
7. Controlled outputs — **deferred entirely (ADR-009);** requires a new ADR + safety model first

**Deterministic MVP rules** (thresholds are per-profile configuration, never hard-coded): cell over/undervoltage, high temp, temp-rise rate, cell delta/imbalance, pack overcurrent, missing critical message, invalid value, CAN bus-off, storage nearly full, connectivity lost.

## Resolved vs open decision gates

Resolved: G3 (Orion Jr 2, ADR-001), G5 (Python, ADR-002), G7 (backend authoritative / Grafana optional, ADR-008). Still open: G1 (marketing cell-sensing claims must be reconciled to the monitoring-only MVP), G2 (first pilot industry), G4 (isolated listen-only CAN hardware), G6 (cloud provider + MQTT broker — broker must not become the system of record).

## Working conventions

- Durable decisions are recorded as ADRs (`docs/adr/`), status **Proposed** or **Accepted**. Never edit an ADR to reverse a decision — supersede it with a new ADR.
- When adding an adapter module, profile field, or message definition, cite the Orion Jr 2 documentation or the unit's configuration export it came from. If a value isn't sourced from real unit data, it doesn't go in.
