# Profile Sourcing — Orion Jr 2

Every value in a `48-10` / `48-20` profile must come from the **actual unit's Orion Jr 2 configuration export** (or its manual), never from the profile name or assumption (ADR-001, ADR-010). This file says what to obtain and how each field is sourced. The field procedure with commands is in [`docs/runbooks/data-collection.md`](../docs/runbooks/data-collection.md).

## The two inputs

1. **Generic Jr 2 documentation** (model-level) — [Wiring & Installation](https://www.orionbms.com/manuals/pdf/jr2_wiring_manual.pdf), [Operation manual](https://www.orionbms.com/manuals/pdf/jr2_operational_manual.pdf), [Spec sheet](https://www.orionbms.com/downloads/documents/orionjr2_specifications.pdf), [Fully Programmable CANBUS](https://www.orionbms.com/features/fully-programmable-canbus/).
2. **This unit's configuration export** (install-level) — produced by the [Orion Jr 2 Utility](https://www.orionbms.com/downloads/orionjr2_utility_stable.exe) over the [CANdapter](https://www.orionbms.com/products/candapter/): a **DBC** of the CAN communication matrix + the saved **profile/settings** file. Broadcasts are customised per install, so the export is the *only* authoritative matrix.

## Open questions the export must resolve

- **Unit count / node IDs.** The Jr 2 supports ~16 series cells per unit, so a **32-cell (`48-10`) or 64-cell (`48-20`)** pack likely uses **multiple Jr 2 units** — confirm how many and their CAN node IDs. This changes what Phase 2 captures and how the profile is structured.
- **Actual cell count** — the 32 / 64 figures are **provisional** (ADR-010) until the export confirms them.

## ADR-010 field → source map

Fill each per unit; cite the export file name + version + date.

| Field | Source |
|---|---|
| Jr 2 firmware version | Orion Utility (shown on connect) |
| Chemistry | Integrator / pack datasheet (not in CAN export) |
| Expected cell count | Config export (**replaces provisional 32/64**) |
| Cell topology (series/parallel) | Integrator / pack build + export |
| Capacity | Integrator / pack datasheet |
| Current-sensor config | Config export (current-sensor settings) |
| Thermistor count + placement | Config export + wiring manual |
| Charger limits | Config export (charger settings) |
| CAN configuration (bitrate, node IDs) | Config export (default 500 kbps) |
| Configured broadcasts: IDs, rates, byte layout, scaling, units | **DBC export** (authoritative) |

## Provenance rule

A profile field with no citation to real unit data does not go in (ADR-010). Until a profile is fully sourced, mark it **unconfirmed** and do not use it to assert a telemetry mismatch is a fault.

## Next step once data arrives

Author `profiles/48-10.*` and `profiles/48-20.*` from the export (one section per unit if multi-unit), load the DBC into the `orion_jr2` decoder via `cantools` (Phase 3), and replay the Part-A captures through it.
