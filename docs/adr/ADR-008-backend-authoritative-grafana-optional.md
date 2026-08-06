# ADR-008: Guardian Backend Authoritative; Grafana Optional

**Status:** Accepted
**Date:** 2026-08-06

## Context

Decision gate G7 weighed Grafana (fastest to stand up) against a custom application (needed for incident workflows). Alerts, incidents, acknowledgement, configuration and fleet state need an authoritative owner with an API and audit trail; a visualisation tool cannot be that owner.

## Decision

Guardian Sentinel's **own backend is the authoritative system of record** for the remote platform: device registry, ingestion, telemetry/event storage, alert and incident lifecycle, acknowledgement, configuration, and audit.

**Grafana is an optional visualisation layer** that reads from the backend's stores (or exposed APIs/datasources). It may be used freely during Phases 5–6 for charts, cell comparison and trend views, but:

- No alerting, incident state, acknowledgement or configuration lives in Grafana.
- Removing Grafana must remove no capability other than convenience dashboards.
- Operator-facing incident workflows are backend/API features, however minimal in the MVP.

## Consequences

- The MVP backend must include at least: MQTT ingestion, storage, device registry, alert/incident state with acknowledgement, and a minimal API — even while Grafana provides the prettiest charts.
- Dashboard build effort in Phase 5 shrinks (Grafana for visuals) without ceding authority to it.
- A future full operator web application replaces Grafana incrementally rather than migrating state out of it.

## Alternatives considered

- **Grafana as the platform (with its alerting)** — rejected: incident lifecycle, audit and acknowledgement would live in a tool not designed to own them.
- **Custom dashboard only, no Grafana** — rejected for MVP: slows Phase 5 for no authority gain.
