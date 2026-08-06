# ADR-001: Orion BMS Jr 2 as the Sole Initial BMS Target

**Status:** Accepted
**Date:** 2026-08-06

## Context

Guardian Sentinel's MVP requires exactly one supported BMS protocol, integrated read-only over CAN (see resolved decision gate G3 in the implementation plan). Supporting multiple BMS vendors or generations before the first end-to-end demonstration would multiply protocol, testing and validation effort without proving the core product.

The Orion product line was selected as the vendor. Within that line, the deployed hardware for the first installation profiles is the Orion BMS Jr 2 only.

## Decision

Guardian Sentinel's first and only supported BMS for the MVP is the **Orion BMS Jr 2**. Compatibility with the original Orion BMS Jr is not assumed or tested.

- Build exactly one adapter: `orion_jr2`, located at `edge/guardian_core/adapters/orion_jr2/` with modules `decoder.py`, `profile.py`, `validation.py`, `messages.py`.
- Validate only against the Jr 2 firmware, configuration export, and CAN messages captured from the actual deployed unit.
- Do not define separate Jr/Jr2 protocol profiles.
- Do not introduce abstractions for multiple Orion generations unless they are required by observed Jr 2 data or a later accepted ADR.
- CAN message definitions, scaling, units and broadcast configuration must be taken from the Jr 2 documentation and the unit's own configuration export — never assumed or invented.

Support for the original Orion Jr, or any other BMS, is a possible future product decision to be made via a new ADR, not an MVP requirement.

## Consequences

- Phase 2 (CAN capture) and Phase 3 (adapter) target a single, concrete device; trace library, decoder tests and validation all reference one firmware/configuration pair.
- The adapter layout stays flat; no generation-dispatch layer, no vendor-neutral protocol framework in the MVP.
- The normalised battery model remains vendor-neutral, but only one adapter feeds it.
- Adding a second BMS later will require a new ADR and may motivate an adapter interface at that time — deliberately deferred.

## Alternatives considered

- **Orion Jr/Jr2 as a family with shared profiles** — rejected: introduces speculative compatibility surface and untestable claims, since only Jr 2 hardware is available for validation.
- **Multi-vendor adapter framework from day one** — rejected: premature abstraction before a single working integration exists.
