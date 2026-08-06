# ADR-009: No Actuation in the MVP

**Status:** Accepted
**Date:** 2026-08-06

## Context

Guardian Sentinel's long-term roadmap includes carefully governed protective actions. Actuation is safety-critical functionality requiring a documented safety model, isolated hardware outputs, deterministic policy checks, tested failure states and human-approval workflows. None of that can be responsibly built before the monitoring foundation is proven, and its presence would dominate the MVP's risk, liability and certification posture.

## Decision

The MVP performs **no actuation of any kind**.

- CAN integration is strictly read-only / listen-only. `guardian-core` and `guardian-can` transmit no frames intended to influence the BMS, chargers, contactors or any connected equipment.
- No hardware control outputs are wired, enabled or exposed.
- No AI/Claude tool exposes actuation; diagnostic tooling is read-only.
- Remote commands are limited to observation, configuration and software-update functions within the security model; none may cause a physical protective action.
- The system's outputs are alerts, findings, evidence and recommendations only.

Controlled outputs remain a roadmap phase (Phase 7). Any actuation work requires, at minimum: a new accepted ADR, a documented action safety model, isolated outputs, deterministic local policy checks independent of cloud and AI, and a human-approval workflow.

## Consequences

- The MVP's safety claim is honest and bounded: earlier detection and better evidence, not intervention.
- Product liability posture is materially simpler for pilots.
- Marketing and website copy must describe intervention strictly as roadmap (consistent with the product-truth reconciliation in gate G1).
- Bench testing needs no live-pack control safeguards beyond read-only bus discipline.

## Alternatives considered

- **Limited actuation (e.g. charger disable relay) in MVP** — rejected: even the smallest actuation path imports the full safety-case burden.
- **AI-recommended, human-executed actions with device assistance** — deferred: acceptable direction for Phase 7 design, not MVP scope.
