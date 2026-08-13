# ADR-015: Broadcast-Only Acquisition; No Diagnostic Transmission in the MVP

**Status:** Accepted
**Date:** 2026-08-13

## Context

The Orion Jr 2 exposes two ways to obtain data over CAN:

1. **Configured periodic broadcasts** — messages the BMS transmits on its own, defined per install in the unit's profile and exported as the DBC communication matrix (`profiles/SOURCING.md`).
2. **OBD2 diagnostic polling** — a request/response protocol (primarily Mode 0x22, ~559 mapped PIDs; default request ID 0x7E3, response ID request+8) documented in the Orion *OBD2 PID Map Usage Guide*. These values are **not broadcast**; each must be actively requested, which requires Guardian to **transmit** on the pack bus.

The manufacturer guidance itself steers the choice: configured periodic messages are recommended for low-latency/high-reliability data, polling for on-demand diagnostics; OBD2 responses carry **no application-level checksum or plausibility check**; and **only one tool should poll a given BMS ECU at a time** — the Orion Utility also uses OBD2, so a polling Guardian could corrupt or block service sessions.

Separately, the *BMS Profile Transfer over CAN* guide documents reading and writing the BMS configuration over CAN. Both directions require **unlocking** the BMS, and unlocking **stops all normal periodic CAN traffic and disengages all BMS-controlled relays** until the BMS is re-locked or restarted. Any profile transfer is therefore an intrusive, pack-offline maintenance operation.

ADR-009 bans actuation but does not, by itself, settle diagnostic transmission: a diagnostic read influences no equipment, yet it is still a transmission on a live pack bus. This ADR settles it.

## Decision

The MVP acquires Orion Jr 2 data **exclusively from configured periodic broadcasts**, decoded via the unit's exported DBC (ADR-001, ADR-010). Guardian transmits **nothing** on the pack CAN bus — no OBD2 requests, no ISO-TP flow control, no security-access, no profile-transfer commands. The capture interface remains listen-only (hardware-enforced where the controller supports it).

Consequences for configuration and commissioning:

- The required signal set for the MVP rules (per-cell voltages, temperatures, pack voltage/current, SoC, status/alarm flags, and any other profile-critical inputs) must be **covered by the unit's configured broadcasts**. Verifying this coverage in the Orion Utility is a mandatory commissioning step (`docs/runbooks/data-collection.md`) — a coverage gap found later reopens this decision via a new ADR, not a workaround.
- The BMS configuration (profile) is read and exported **only** via the Orion Utility during commissioning or service — never by Guardian over CAN, because even a read requires the unlock and therefore takes the pack offline (relays disengaged).
- The configured OBD2 ECU ID is recorded as a profile field (ADR-010) even though Guardian never uses it, so that Utility diagnostic traffic observed in captures (0x7E3/0x7EB by default, but profile-configurable and changeable by profile activation) is recognised and catalogued rather than flagged as unknown bus traffic.
- The *OBD2 PID Map* remains a **reference artifact**: an authoritative cross-check for scaling, signedness, units and loaded/present semantics when validating the DBC-driven decoder — not a runtime data source.

## Deferred capabilities (explicitly not forbidden forever)

The following are **deferred, not rejected**. Each requires a new accepted ADR, and the listed preconditions, before any implementation:

1. **OBD2 diagnostic polling by Guardian.** Justified only if observed broadcast coverage proves insufficient for required signals. Preconditions: a transmit-capable, isolated interface qualified for the pack bus; single-poller arbitration with the Orion Utility (never poll while a service session is active); one-outstanding-request discipline with timeouts; validation compensating for the absence of an application-level checksum; and an explicit revision of the listen-only constraint in `CLAUDE.md` (constraint #2) distinguishing *diagnostic transmission* from *actuation* (ADR-009 remains untouched — polling influences no equipment).
2. **Remote BMS profile deployment via Guardian ("deploy config through GS").** A genuinely valuable fleet capability, and fully documented by the manufacturer — but it is inherently a **pack-offline maintenance operation**: unlock stops periodic traffic and disengages every relay for the duration of transfer → verify/apply → checksum comparison → re-lock. It is therefore Phase-7-class: it needs an operator-initiated, operator-confirmed workflow; pre-flight checks that taking the pack offline is safe; the full security-access handling (16-bit and password-protected 64-bit paths, seed lifetime, two-failure lockout); per-block acknowledgement and bounded retries; tolerance for the diagnostic ECU ID changing at activation; mandatory active-profile checksum verification before reporting success; lock attempted on **every** exit path; and a tested recovery story for power loss mid-write. Never a background or automated operation.
3. **BMS profile readback via Guardian.** Same unlock/pack-offline burden as (2); useful only as post-write verification within that same governed workflow.

Design hooks already in place so these stay additive: the typed-event model (ADR-004) and health model (ADR-012) should treat a "BMS unlocked / maintenance window" as a first-class expected state — during Utility service work the pack's broadcasts stop, which must read as `fault(monitoring)` with a *known maintenance cause*, not an unexplained outage.

## Consequences

- Guardian's MVP bus footprint is zero: it cannot disturb the pack, the BMS, or an Orion Utility service session, and the listen-only claim is verifiable at the interface level (G4 selection criterion).
- Signal availability becomes a commissioning-time contract: broadcast coverage is verified on site before Phase 2 sign-off, and the profile's "configured broadcasts" field is the enforcement point.
- "Read-only" is now precise: ADR-009 governs actuation; this ADR governs transmission. Relaxing either is a separate, explicit decision.
- The profile-deployment feature has a recorded intent and a defined bar to clear, rather than being silently absent or accidentally introduced.

## Alternatives considered

- **OBD2 polling in the MVP** — rejected: requires transmission on a live pack bus, conflicts with the Utility's single-poller expectation, lacks an application-level checksum, and duplicates data the profile can simply broadcast.
- **Hybrid (broadcasts + occasional polling for gaps)** — rejected for MVP: inherits all polling preconditions for marginal benefit; the correct MVP fix for a coverage gap is configuring the broadcast in the profile at commissioning.
- **Profile read/write via Guardian in the MVP** — rejected: unlock takes the pack offline (relays disengaged), making it an operational intervention squarely outside a monitoring MVP (ADR-009's spirit), with substantial failure-mode surface documented by the manufacturer.
