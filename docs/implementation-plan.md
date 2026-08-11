# Guardian Sentinel — Implementation Plan

**Version:** 0.8
**Date:** 2026-08-11
**Status:** Accepted working plan. Durable decisions live in [ADRs](adr/README.md); this plan references them and does not restate their rationale.

**Changes from v0.7 (final-review resolutions — two remaining blockers):** (1) **Tier-2 replay safety** is now solved, not deferred: safety transitions carry a **deterministic effect identity**, the single operational writer applies them with **atomic duplicate suppression**, and safety outputs are **gated until core converges to live** — so a restart cannot duplicate a finding or replay a stale close that transiently clears an active incident (ADR-011/007). No exactly-once transport or durable telemetry. (2) The **loss contract wording is unified** across ADR-003/005/006/014, CLAUDE.md and the plan on one statement: *known or inferred loss degrades data-confidence and can never appear healthy; some loss may remain undetectable in the MVP.* Absolute "never silent / always a gap" claims removed. Non-blocking cleanups: ADR-004 deterministic-timeline claim scoped to within-session and collision-conflict quarantine defined; ADR-012 conservative-summary states/precedence frozen.

**Changes from v0.6 (fourth-review resolutions — safety-boundary precision, still best-effort):** ADR-012 split into **two axes** — battery condition (asserted only from fresh data; `unknown` when unseen, never faulted for absent data) vs data confidence (monitoring), with a conservative summary carrying a reason domain (battery/monitoring/configuration/decoder), so "can't see the pack" is never shown as "pack fault." ADR-003 classifies loss **known/inferred/undetectable** (inferred via expected-broadcast liveness), narrows the invariant to "known-or-inferred loss never appears healthy," and splits capture-vs-interpretation ownership. ADR-004 specifies session-id construction and **unknown-session handling** (implicit incomplete boundary + degrade confidence; deterministic timeline limited to one session). Tier-2 **duplicate-on-restart** was flagged here and is fully resolved in v0.8 (deterministic effect-id + operational-writer dedup + output gating, ADR-011). Phase 2 now **measures** nominal/peak fps for a Phase-4 drop budget; pinning ack reworded (evidence-present, not power-loss-durable).

**Changes from v0.5 (simplified first cut — keep up with the CAN bus, accept missed data):** the ingestion design is now **best-effort by default and deliberately allowed to miss data** — a hardware/driver concern, not something the edge process pretends to solve. Priority is keeping the receive loop ahead of a high-speed CAN bus. ADR-005 rewritten to this stance (tiers unchanged: Tier 0 lossy stream, Tier 1 best-effort pre-roll, Tier 2 durable safety state); it no longer claims exact/never-silent loss. ADR-004 identity simplified to a **collision-resistant session id** (no durable generation counter or recovery path); cross-session order is best-effort by start time. ADR-011 relaxed to **best-effort idempotency** (dedup only where cheap/visibly-wrong; strict semantics deferred). ADR-003 gap handling made honest (open-ended/unknown-extent gaps, separate IPC/log loss counters, no exactness claim). ADR-012 gains a **data-confidence axis** so a monitoring gap invalidates `healthy` without being confused for battery condition. ADR-014 offline gate aligned to test durable Tier-2 and *permit* Tier-0/1 loss. ADR-006/CLAUDE.md drop "replay checkpoint" for a lightweight last-seen marker. Over-long ADRs (004/005/011/013) trimmed. Zero-loss/durable ingestion and strict idempotency are a **future ADR** when a deployment needs them. *(The v0.3–v0.4 zero-loss machinery — durable session generation, dual watermarks, emergency journal, iterative catch-up — was explored during review and intentionally simplified out; it is not in the current ADRs.)*

**Changes from v0.2 (architecture-review resolutions):** delivery/identity/idempotency contract adopted (ADR-011); explicit battery health-state model adopted (ADR-012); storage quotas and exhaustion policy adopted (ADR-013); local-operation-independent-of-remote-and-AI adopted with a distinct offline-first acceptance gate (ADR-014). Cross-session/boot ordering and clock-confidence semantics sharpened (ADR-004); canonical ingestion path, replay→live handoff, checkpoint-advancement rules and evidence-pinning reverse channel specified (ADR-003/005); two-file SQLite topology confirmed as the accepted design (ADR-006). Installation cell-count figures marked provisional pending configuration-export provenance (ADR-010). Removed the speculative requirement that future non-CAN inputs mirror `guardian-can`.

**Changes from v0.1:** G3, G5 and G7 resolved by ADR; Orion BMS Jr 2 is the sole BMS target (ADR-001); two-process edge architecture, typed event envelope and replayable ingestion log adopted (ADR-003/004/005); trace files promoted to first-class replay source; restart/replay, clock correction, CAN-health ordering and database writer ownership added to phases; installation profiles 48-10/48-20 adopted (ADR-010).

---

## 1. Objective

Build a read-only edge prototype that:

1. Captures the CAN stream of an **Orion BMS Jr 2** (ADR-001)
2. Normalises pack and cell telemetry against an explicit installation profile (ADR-010)
3. Stores it locally in SQLite (ADR-006/007)
4. Detects a small set of safety-relevant conditions deterministically
5. Publishes alerts and telemetry securely over MQTT to Guardian's authoritative backend (ADR-008)
6. Continues operating fully offline, uploading buffered data on reconnection

**Local acceptance gate (Definition of Done, part A — must pass first):**
Exercised with DNS, MQTT, backend, Grafana and AI all unreachable from cold boot (ADR-014): the Orion Jr 2 (or its trace replay) produces CAN telemetry → `guardian-can` captures it → `guardian-core` decodes it via the `orion_jr2` adapter → pack/cell state is visible with an explicit health state (ADR-012) and snapshot quality → a simulated abnormal condition triggers a local finding with linked evidence (pre-roll persisted on trigger) → a local alert is raised and **durably** stored (Tier 2, ADR-005) → `guardian-core` is restarted mid-stream, resumes from its last-seen marker, and re-reads the buffered window through the same decoder path with **Tier-2 dedup + output-gating** so no finding is duplicated and no active incident is transiently cleared (ADR-011); un-buffered loss that is **known or inferred degrades health/data-confidence** (undetectable residual loss acknowledged), never a healthy claim (ADR-005/012) → all of this remains true with no network and no AI, within bounded storage/backlog and reserve (ADR-013).

**End-to-end demo target (Definition of Done, part B):**
Building on part A: a remote alert is delivered → network is cut and local operation continues → buffered data uploads duplicate-safe after reconnection (ADR-011) → a concise Claude-generated incident explanation is produced from captured evidence. Remote delivery and the Claude summary are downstream of local truth; their failure never alters local findings or alert state (ADR-014).

---

## 2. Scope

### In scope (MVP)

- Orion BMS Jr 2, read-only CAN, sole adapter `orion_jr2` (ADR-001)
- Installation profiles `48-10` (32 cells) and `48-20` (64 cells), explicitly defined (ADR-010)
- Two edge processes: `guardian-can` and `guardian-core` (ADR-003), Python (ADR-002)
- Versioned typed ingestion-event envelope (ADR-004)
- Bounded ingestion buffer with **tiered durability** — best-effort, may-miss-data stream + explicit gaps by default, durable Tier-2 safety state, best-effort pre-roll incident evidence; zero-loss tier deferred (ADR-005); **best-effort idempotency** (ADR-011)
- SQLite persistence, two-file operational/telemetry separation, single writer per database (ADR-006/007); per-consumer storage quotas with a safety reserve and exhaustion policy (ADR-013)
- Deterministic local rules (thresholds, rate-of-change, staleness, coherence) over an explicit snapshot health-state model (ADR-012)
- MQTT 5 over TLS with store-and-forward into Guardian's backend; Grafana as optional visualisation (ADR-008); local safety function independent of remote and AI availability (ADR-014)
- Device self-health monitoring
- Secure remote access for development (Tailscale/WireGuard)

### Explicitly out of scope (MVP)

- Any actuation (ADR-009)
- Original Orion Jr compatibility, or any second BMS (ADR-001)
- Multi-generation/multi-vendor adapter abstractions unless required by observed Jr 2 data or a later ADR (ADR-001)
- AI-issued safety actions; independent cell-level sensing hardware; universal BMS support; safety certification; destructive thermal-runaway testing; consumer enclosure

### Data-quality rule (applies everywhere)

A missing or stale cell value remains explicitly missing or stale — never carried forward as current. Every assembled battery snapshot records: expected cell count, received fresh-cell count, missing/stale cell indices, coherence, quality, and source/decoder version (ADR-010), and resolves to an explicit health state in which `healthy` requires complete, fresh critical inputs (ADR-012) — quality metadata alone never permits an incomplete snapshot to be reported as healthy.

---

## 3. Decision Gates

| # | Decision | Status |
|---|----------|--------|
| G1 | Product architecture reconciliation (marketing cell-sensing claims vs CAN-gateway reality) | **Open.** ADR-009 sharpens it: MVP outputs are alerts/evidence only; intervention and independent sensing are roadmap. Marketing copy must align. |
| G2 | First target industry + pilot | **Open.** A *provisional* market hypothesis (stationary storage / industrial) is suggested by the `48-*` profile labels, but per ADR-010 those names are labels only and the configurations are unconfirmed — this inference must not drive commitments until backed by the unit's configuration export or independent pack specifications. Confirm pilot. |
| G3 | First BMS model | **Resolved — ADR-001:** Orion BMS Jr 2, sole target. |
| G4 | CAN interface hardware | **Open.** Must support SocketCAN, galvanic isolation, listen-only; validate against the Jr 2's configured bus settings from its configuration export. |
| G5 | Language boundary | **Resolved — ADR-002:** Python for both processes in the MVP. |
| G6 | Cloud provider + MQTT broker | **Open.** Constraint from ADR-008: broker feeds Guardian's own backend; broker choice must not become the system of record. |
| G7 | Dashboard technology | **Resolved — ADR-008:** Guardian backend authoritative; Grafana optional visualisation. |

---

## 4. Confirmed Stack

- **Compute:** Raspberry Pi CM4, 4 GB RAM, 16 GB eMMC; Waveshare CM4 PoE 4G carrier; SIM7600X-H-M2 (verify AU bands)
- **OS/services:** Raspberry Pi OS Lite 64-bit (Bookworm), systemd, hardware watchdog
- **Edge runtime:** Python (ADR-002); `guardian-can` + `guardian-core` (ADR-003)
- **CAN:** SocketCAN, can-utils, python-can, cantools
- **IPC:** Unix domain socket, MessagePack-framed typed envelope (ADR-004)
- **Raw evidence:** bounded RAM ring + best-effort rotated/compressed on-disk log, tiered durability, replayable for tests (ADR-005)
- **Storage:** SQLite, two-file operational + telemetry separation, single writer per DB (ADR-006/007); quotas + safety reserve (ADR-013)
- **Telemetry:** MQTT 5 over TLS, store-and-forward → Guardian backend (ADR-008); best-effort, duplicate-safe by idempotency token (ADR-011)
- **Networking:** NetworkManager, ModemManager, GPSD; Tailscale/WireGuard (dev)

---

## 5. Phases

Durations are rough part-time single-developer estimates; treat as relative sizing.

### Phase 1 — Hardware Bring-Up (2–3 weeks)

As v0.1 (eMMC flash, Ethernet/PoE, modem + AU bands + 48 h cellular soak, GNSS decision, remote access, watchdog, 20+ hard power cycles, baseline image), plus:

- **Select and validate CAN hardware (G4)** against the Jr 2's configured bus parameters (from its configuration export — never assumed)
- **Clock discipline baseline:** confirm NTP behaviour on cellular attach; verify monotonic clock use in test scripts; document how wall-clock steps will be captured as clock-adjustment events (ADR-004)

**Exit criteria:** unit survives repeated power loss, 48 h unattended cellular uptime, CAN interface passes loopback and two-node bench tests at the Jr 2's bus rate.

### Phase 2 — CAN Capture (1–2 weeks)

- Bring up SocketCAN against the live Orion Jr 2, listen-only
- Record representative sessions (idle, charging, discharging, safely reproducible alarm states) **directly in the ingestion-log event format (ADR-004/005)** so every trace is replayable through the production path
- Catalogue every recurring CAN ID with frequency and tentative meaning, cross-checked against Jr 2 documentation and the unit's configuration export
- Capture CAN state-change and error events alongside frames to validate in-band health ordering
- **Measure the actual workload:** nominal and peak frames/second, bus utilisation, and burst shape from the real configured unit — this trace is the Phase 4 load, and the accepted drop budget and gap-detection latency are frozen from it, not invented
- Populate `traces/` as the versioned trace library

**Exit criteria:** trace library covers all routine operating states of the Jr 2; traces replay cleanly through the envelope decoder; every recurring CAN ID catalogued; **nominal/peak fps, bus utilisation and burst shape recorded** for Phase 4.

### Phase 3 — Orion Jr 2 Adapter + Normalised Model (2–3 weeks)

- Implement the **sole adapter** `edge/guardian_core/adapters/orion_jr2/` (`decoder.py`, `profile.py`, `validation.py`, `messages.py`) per ADR-001 — message definitions from Jr 2 documentation and the actual unit only
- Implement installation-profile loading and validation for `48-10`/`48-20` (ADR-010); profile/telemetry mismatch is a loud fault
- Per-signal freshness, plausibility and staleness validation; snapshot assembly with the full quality metadata set, and derivation of the **two-axis** model (ADR-012): battery condition (`unknown` unless fresh data supports otherwise) and data confidence, plus a conservative summary with reason domain — `healthy` requires both axes ok
- Thermistor-broadcast decoding over the same CAN path (non-CAN sensor inputs are out of scope for the Orion Jr 2 MVP; any future sensor architecture is a later ADR, not a constraint imposed now)
- Replay-driven test suite from the Phase 2 trace library — replay and live share one decoder path (ADR-005)
- No multi-generation abstractions (ADR-001 constraint)

**Exit criteria:** adapter tests green against the full trace library; stale/invalid data flagged, never passed through; profile mismatch demonstrably faults; an incomplete or stale snapshot never resolves to `healthy` (ADR-012), verified at startup, on partial broadcast cycles, and under stale-value invalidation.

### Phase 4 — Local Guardian Runtime (3–4 weeks)

- Stand up both processes under systemd with the IPC boundary and non-blocking rules (ADR-003), implementing the **best-effort ingestion path** (RAM ring + best-effort on-disk log, **no per-frame `fsync`**; drops surface as sequence discontinuities → explicit gap/overflow events; never block the receive loop)
- **Tiered durability (ADR-005):** Tier 0 stream/telemetry best-effort (lossy, duplicate-tolerant); Tier 1 incident evidence via RAM **pre-roll persisted on trigger** (best-effort); Tier 2 operational safety state (alert/incident, acks, config, decoder/profile version) **durable on change**, with **deterministic effect identity + atomic operational-writer dedup + safety-output gating until convergence** so a restart cannot duplicate a finding or transiently clear an active incident (ADR-011/007). Telemetry idempotency and durable resume stay best-effort (a later ADR)
- **Restart/resume (MVP):** `guardian-core` restart → resume from lightweight last-seen marker, re-read the still-buffered window through the same decoder path; **Tier-2 transitions deduped by deterministic identity + safety outputs gated until convergence** (ADR-011) so replay can't duplicate a finding or transiently clear an active incident; known/inferred un-buffered loss degrades health/data-confidence (some undetectable); restart-mid-stream, stale-close-on-replay, and buffer-overflow-→-gap tests are standing regressions. *(Zero-loss/durable ingestion tier is a future ADR.)*
- **Typed event handling (ADR-004):** frames, CAN state changes, CAN errors, interface restarts, clock adjustments, ingestion overflow, ingestion gaps (incl. open-ended/unknown-extent), session start/end — ordered **within a session by sequence, across sessions best-effort by session-start time**; identity is a collision-resistant **session id** (no durable generation counter)
- **Clock correction handling:** wall-clock steps recorded as events; timelines remain reconstructible across steps via monotonic time
- SQLite: **two separate database files** (operational + telemetry), WAL, batched telemetry writes, immediate durable writes for findings/alert transitions/bus-off/config changes; **single owning writer per database file with bounded submission queues — MQTT delivery-state updates go through the operational writer** (ADR-006/007); observations owned by the telemetry writer, device-health and evidence-pin references by the operational writer
- Evidence pinning via the core→can reverse control channel (pin request; ack = **accepted + evidence-currently-present / pin-attempted**, *not* a power-loss-durable guarantee — Tier 1 is best-effort; **startup reconciliation** of core references vs can's current pin index → evidence-health fault on drift); ingestion-log bounds tuning vs eMMC endurance
- **Storage quotas and exhaustion policy (ADR-013):** per-consumer quotas (ingestion log, pinned evidence within it, both DBs, MQTT backlog) within a device budget; a reserve only *current* operational safety state and alert uplinks may use; **compaction** of closed incidents/superseded transitions/acked items to keep the protected set bounded; safety-ordered eviction with recorded eviction/gap events; defined terminal behavior when the reserve is full of protected records (explicit prioritised loss, never silent stall); storage-pressure device-health and alerts
- Deterministic MVP rules (cell over/undervoltage, high temp, temp-rise rate, cell delta/imbalance, pack overcurrent, missing critical message, invalid value, CAN bus-off, storage nearly full, connectivity lost) — thresholds are profile configuration, never hard-coded
- Alert lifecycle (hysteresis, dedup, escalation, first-occurrence preservation); incident snapshots; device self-health incl. consumer lag, dropped-frame counts, writer queue depth
- Local REST API + minimal status page

**Exit criteria:** the receive loop keeps up at the **Phase 2-measured nominal/peak rate** without stalling, with receive-loop latency, CPU/memory, queue high-water marks and SocketCAN/kernel overflow counters recorded and the drop budget + gap-detection latency frozen from that evidence; every MVP rule fires and clears under replay and fault injection; known/inferred loss always degrades data-confidence (never a healthy claim over a gap), undetectable loss acknowledged; core restart mid-incident re-reads the buffered window with **Tier-2 dedup + output-gating verified** (no duplicate finding, no transient clear/reclose of an active incident, no out-of-order safety uplink — ADR-011); known/inferred un-buffered loss degrades data-confidence (undetectable residual acknowledged); Tier-2 safety state survives reboot (active alarm not forgotten); storage exhaustion degrades in the ADR-013 eviction order with the reserve intact; **steady-state disk writes stay bounded with no per-frame `fsync`**; the **offline-first local acceptance gate (ADR-014)** passes with DNS/MQTT/backend/Grafana/AI down from boot; one-week soak with bounded resources and no writer contention.

### Phase 5 — Remote Telemetry + Backend (2–3 weeks; requires G6)

- Device identity + per-device certificates; MQTT 5 over TLS (mutual TLS where practical)
- Store-and-forward with priority (alerts first), backlog throttling within bounded quota (ADR-013), duplicate-safe delivery via idempotency token (ADR-011); delivery state via the operational writer (ADR-007)
- **Guardian backend (ADR-008):** ingestion, storage, device registry, alert/incident state with acknowledgement, minimal API — authoritative
- Grafana attached read-only for pack/cell views, trends, cell comparison (optional layer)
- Offline/reconnect testing: network cut mid-incident; 24 h outage → zero loss within retention bounds; reconnect upload is duplicate-safe (ADR-011)

**Exit criteria:** the offline-first local gate (Definition of Done part A, ADR-014) already passes from Phase 4; part B runs end-to-end excluding the Claude summary, including the core-restart step; remote/backend failure demonstrably leaves local findings and alert state unchanged.

### Phase 6 — Diagnostic Intelligence (2–3 weeks)

- Derived metrics (cell-vs-median deviation, trend slopes, divergence)
- Observation → finding correlation with linked evidence (raw evidence in ingestion log / observations / findings)
- Operator-readable incident timeline (correctly ordered across clock adjustments and CAN health events)
- Claude-assisted incident summaries via read-only tools; every conclusion cites evidence; all inputs/outputs audited; **no actuation tools (ADR-009)**; AI is strictly advisory and downstream of all decisions — its failure, timeout or absence never affects findings, alerts or health state (ADR-014)

**Exit criteria:** a simulated incident produces an evidence-linked finding and a Claude-generated explanation an operator would accept.

### Phase 7 — Controlled Outputs (future, not scheduled)

Deferred entirely per ADR-009. Any work here begins with a new accepted ADR, a documented action safety model, isolated hardware outputs, deterministic local policy checks, and human-approval workflows.

---

## 6. Cross-Cutting Workstreams

- **Simulator / replay harness:** the ingestion log *is* the harness (ADR-005) — recorded Jr 2 traces plus synthetic fault injection in envelope format, replayed through the production path
- **Fault injection library:** stuck sensors, implausible jumps, missing messages, reordering, BMS reboot, bus-off, interface restarts, clock steps, overflow, expired-replay gaps, storage-full, corrupted config, core-restart-mid-incident
- **Security:** device identity from Phase 1; signed updates by Phase 5; production provisioning deferred but not designed-out
- **Documentation:** ADRs for durable decisions (append via new ADRs, never silent edits); adapter protocol notes sourced from Jr 2 docs and the unit's configuration export; runbooks
- **Pilot evidence:** demo recording, incident report samples, soak/uptime data

---

## 7. Timeline Summary (indicative)

| Phase | Duration | Cumulative |
|-------|----------|------------|
| 1 — Hardware bring-up | 2–3 wks | ~3 wks |
| 2 — CAN capture | 1–2 wks | ~5 wks |
| 3 — Jr 2 adapter | 2–3 wks | ~8 wks |
| 4 — Local runtime | 3–4 wks | ~12 wks |
| 5 — Remote telemetry + backend | 2–3 wks | ~15 wks |
| 6 — Diagnostics + Claude | 2–3 wks | ~18 wks |

Roughly 4–5 months part-time to the full demo. Phase 4 carries the most new scope (restart/replay, writer ownership); Phase 3 shrinks slightly with the single-device target.

---

## 8. Top Risks

1. **G1 unresolved** — marketing cell-sensing/impedance claims vs read-only CAN-gateway reality; ADR-009 makes the MVP boundary explicit, but copy must follow
2. **Jr 2 protocol coverage & profile provenance** — required signals must actually be present in the unit's configured broadcasts, and the `48-10`/`48-20` cell counts (32/64) are provisional until confirmed from the unit's configuration export (ADR-010); verify both against the export early in Phase 2
3. **Cellular reliability** — SIM7600 AU band/carrier validation in Phase 1, not at deployment
4. **eMMC endurance vs replay depth** — ingestion-log and retention bounds are a real tuning task, not defaults
5. **Scope creep** — into actuation (ADR-009) or multi-BMS abstraction (ADR-001); both are ADR-gated
6. **Marketing stats provenance** — 73% precursor figure and <3 min escalation window need sources before tender/website use

---

## 9. Immediate Next Actions

1. Decide G1 formally (recommended: align copy with ADR-009's monitoring-only MVP)
2. Obtain the Jr 2's documentation set and the actual unit's configuration export (feeds ADR-010 profile fields and Phase 2/3)
3. Shortlist isolated CAN interface hardware (G4)
4. Author the `48-10` and `48-20` profile definitions from real unit data (ADR-010)
5. Begin Phase 1 with hardware on hand
