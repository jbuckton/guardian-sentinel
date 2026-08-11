# ADR-010: Installation Profiles `48-10` (32 Cells) and `48-20` (64 Cells)

**Status:** Accepted
**Date:** 2026-08-06

## Context

The first deployments cover two known physical configurations. Guardian Sentinel must validate incoming telemetry against what the installation is *supposed* to look like; that expectation has to be explicit, not inferred. Profile names are product/installation labels, and labels must never be a source of technical truth.

## Decision

The first supported installation profiles are:

- **`48-10`** — expected cell count: 32 *(provisional)*
- **`48-20`** — expected cell count: 64 *(provisional)*

These names are installation/product profiles only. **Do not infer battery chemistry, series/parallel topology, voltage thresholds or thermistor layout solely from the profile names.**

**Provenance:** the 32- and 64-cell figures are provisional working assumptions, not yet confirmed against hardware. Before a profile is used to validate a real deployment, its expected cell count and every field below must be populated from **that unit's Orion Jr 2 configuration export and documentation**, and the profile record must cite that source (export file/version and date). A profile whose fields are not backed by an actual configuration export is marked unconfirmed and must not be used to assert a telemetry mismatch is a fault (see G2/Phase 2 in the implementation plan).

Each deployed profile must explicitly define:

- Orion BMS Jr 2 firmware version (sole supported BMS, ADR-001)
- Chemistry
- Expected cell count
- Cell topology
- Capacity
- Current-sensor configuration
- Thermistor count and placement
- Charger limits
- CAN configuration
- Configured Orion Jr 2 broadcasts

Profile definitions live in `profiles/` as versioned configuration consumed by `guardian_core/adapters/orion_jr2/profile.py`. Field values are populated from the actual unit's documentation and configuration export — never invented or defaulted from the profile name.

### Validation obligations

- A mismatch between profile expectations and observed telemetry (e.g. cell count, broadcast set) is a loud, explicit fault — never silently reconciled.
- Every assembled battery snapshot records expected cell count, received fresh-cell count, missing/stale cell indices, coherence, quality, and source/decoder version, evaluated against the active profile.
- Recording this quality metadata is necessary but **not sufficient**: metadata alone does not stop an incomplete snapshot from being reported as healthy. The snapshot's battery-condition and data-confidence axes are governed by **ADR-012**; this profile's expectations are inputs to that model, and a profile mismatch yields `fault(configuration)` (data-confidence), leaving battery condition `unknown` — never a battery fault.

## Consequences

- Misconfiguration (wrong profile on a unit, changed Orion configuration) is detectable immediately rather than corrupting downstream findings.
- Rules and thresholds are configuration-driven per profile; nothing chemistry- or topology-specific is hard-coded.
- Adding a profile is a configuration-plus-review exercise, not a code change, provided the Orion Jr 2 remains the BMS.

## Alternatives considered

- **Deriving expectations from live discovery** — rejected as the source of truth: discovery cannot distinguish a differently-built pack from a faulty one; it may inform validation but not define expectations.
- **Encoding topology in profile names** — rejected: names drift from reality; explicit fields do not.
