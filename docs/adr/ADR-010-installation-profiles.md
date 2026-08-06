# ADR-010: Installation Profiles `48-10` (32 Cells) and `48-20` (64 Cells)

**Status:** Accepted
**Date:** 2026-08-06

## Context

The first deployments cover two known physical configurations. Guardian Sentinel must validate incoming telemetry against what the installation is *supposed* to look like; that expectation has to be explicit, not inferred. Profile names are product/installation labels, and labels must never be a source of technical truth.

## Decision

The first supported installation profiles are:

- **`48-10`** — expected cell count: 32
- **`48-20`** — expected cell count: 64

These names are installation/product profiles only. **Do not infer battery chemistry, series/parallel topology, voltage thresholds or thermistor layout solely from the profile names.**

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

## Consequences

- Misconfiguration (wrong profile on a unit, changed Orion configuration) is detectable immediately rather than corrupting downstream findings.
- Rules and thresholds are configuration-driven per profile; nothing chemistry- or topology-specific is hard-coded.
- Adding a profile is a configuration-plus-review exercise, not a code change, provided the Orion Jr 2 remains the BMS.

## Alternatives considered

- **Deriving expectations from live discovery** — rejected as the source of truth: discovery cannot distinguish a differently-built pack from a faulty one; it may inform validation but not define expectations.
- **Encoding topology in profile names** — rejected: names drift from reality; explicit fields do not.
