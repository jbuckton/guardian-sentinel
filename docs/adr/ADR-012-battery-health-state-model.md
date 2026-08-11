# ADR-012: Battery Condition and Data Confidence as Separate Axes

**Status:** Accepted
**Date:** 2026-08-07

## Context

Stale or missing data must never masquerade as a healthy battery (README). But it must equally never masquerade as a *faulty* battery: "we cannot currently see the pack" is a monitoring problem, not a pack condition. ADR-010 records per-snapshot quality metadata, but metadata alone lets each consumer draw its own conclusion, and a single health enum tempts collapsing "missing critical telemetry" into "battery fault." Both failures — calling an unseen pack healthy, and calling it faulty — are wrong.

## Decision

Every assembled snapshot carries **two separately-computed fields**, plus a conservative summary for simple consumers. `guardian-core` computes all three; consumers render them and never re-derive.

### Two axes

- **Battery condition** — what the pack is doing: `unknown` / `ok` / `concern` / `fault`. Asserted **only from sufficient, fresh data**. When critical inputs are missing or stale it is `unknown` — never inferred, and never set to `fault` merely because data is absent.
- **Data confidence** (monitoring health) — whether we can currently see the pack: `ok` / `degraded` / `fault`. Driven by ingestion gaps (ADR-003/005), staleness, profile/config validity, and decoder health — never by pack values.

These are independent: "pack looks bad, data good" and "pack unknown, data bad" are different situations and must never be presented as the same.

### Conservative summary + reason domain

For a consumer that wants one status, core emits a **conservative summary** (the worse of the two axes) tagged with a **reason domain**: `battery` / `monitoring` / `configuration` / `decoder`. A summary of `fault` therefore always says *why*: `fault(battery)` (a real pack condition on good data) is categorically different from `fault(monitoring)`, `fault(configuration)`, or `fault(decoder)`.

**Conservative summary — states and precedence.** The summary is one of `healthy` / `degraded` / `fault`, computed by a fixed precedence (worst-wins), each fault carrying its reason domain:

1. **`fault`** if data confidence is `fault` (reason `monitoring`/`configuration`/`decoder`, per cause) **or** battery condition is `fault` (reason `battery`). When both are `fault`, both reasons are reported, `monitoring` first (you cannot trust a battery fault you cannot currently see).
2. else **`degraded`** if either axis is `degraded`/`concern` (battery `concern` → reason `battery`; data `degraded` → reason `monitoring`).
3. else **`healthy`** — asserted **only** when battery condition is `ok` *and* data confidence is `ok` (complete, fresh critical inputs, no fault on either axis). Absence of evidence is never `healthy`.

This precedence is the frozen contract the API/MQTT field commits to.

### Determination (criticality is per-profile config, ADR-010; never hard-coded)

- Missing/stale **critical** input ⇒ data confidence `fault`, battery condition `unknown`, reason `monitoring` — **not** `fault(battery)`. Missing/stale non-critical ⇒ data confidence `degraded`.
- **Ingestion gap** ⇒ immediately invalidates `healthy`; a **critical or prolonged** gap ⇒ `fault(monitoring)`, battery condition `unknown`. Recovery to `healthy` needs a complete fresh broadcast cycle plus the healthy-state dwell.
- **Startup / partial broadcast cycle** ⇒ battery condition `unknown`; never `healthy`.
- **Profile mismatch** ⇒ `fault(configuration)`; **decoder failure / unknown schema** ⇒ `fault(decoder)`; both leave battery condition `unknown`.
- **Stale-value invalidation:** a value past its freshness bound is treated as missing, not carried forward.
- **Real pack conditions** (over/under-voltage, over-temp, imbalance, …) on fresh, sufficient data are the **only** path to battery condition `concern`/`fault(battery)`.

### Representation and recovery

- **API and MQTT** expose both fields and the summary's reason domain; Grafana (ADR-008) visualises them read-only. A consumer showing one light must map from the summary and its domain.
- **Hysteresis:** transitions toward `healthy` require a configured dwell; transitions toward any `fault` are immediate.
- The axes feed, but are distinct from, the alert lifecycle: a monitoring fault and a battery fault raise different alerts.

## Consequences

- "Missing/stale never looks healthy" **and** "cannot-see-the-pack never looks like a pack fault" are both testable invariants with one owner.
- Operators can distinguish a battery problem from a monitoring problem at a glance, via the reason domain.
- Rules, API, and uplink depend on these fields; changing their meaning is a new ADR.

## Alternatives considered

- **One health enum mixing battery and monitoring** — rejected: collapses "unseen" into "faulty" (or "healthy"), the exact confusion this ADR exists to prevent.
- **Quality metadata only, each consumer decides** — rejected: divergent, un-auditable conclusions.
- **Deriving criticality from signal names** — rejected: criticality is a profile fact (ADR-010).
