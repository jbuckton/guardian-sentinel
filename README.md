# Guardian Sentinel

Edge-based lithium battery monitoring and assurance platform.

Guardian Sentinel is an independent, read-only monitoring gateway that sits alongside a battery management system, observes it over CAN, validates and stores telemetry locally, detects abnormal and deteriorating behaviour, and delivers alerts and telemetry to a remote backend while remaining fully functional offline.

**Guardian Sentinel's first and only supported BMS for the MVP is the Orion BMS Jr 2. Compatibility with the original Orion BMS Jr is not assumed or tested.**

## Repository status

Documentation only. No source code has been implemented yet. The `edge/` tree below defines the intended layout; each directory contains a placeholder README describing its future contents.

## Repository layout

```
guardian-sentinel/
├── README.md
├── docs/
│   ├── implementation-plan.md      # Phased plan with decision gates G1–G7
│   └── adr/                        # Architecture Decision Records
│       ├── README.md               # ADR index and template
│       └── ADR-001 … ADR-010
├── edge/
│   ├── guardian_can/               # (future) SocketCAN ingestion process
│   └── guardian_core/              # (future) decoding, rules, persistence, uplink
│       └── adapters/
│           └── orion_jr2/          # (future) sole MVP BMS adapter
│               ├── decoder.py
│               ├── profile.py
│               ├── validation.py
│               └── messages.py
├── profiles/                       # (future) installation profile definitions (48-10, 48-20)
└── traces/                         # (future) versioned CAN trace library for replay testing
```

## Governing principles

- Safety before sophistication; read-only before control (no actuation in the MVP — ADR-009)
- Edge before cloud: the device must remain useful and safe when disconnected
- Fail explicitly: stale or missing data must never masquerade as a healthy battery
- Evidence before conclusions: every finding links to the telemetry behind it
- Do not introduce abstractions for multiple Orion generations unless required by observed Jr 2 data or a later accepted ADR

## Key documents

- [Implementation plan](docs/implementation-plan.md)
- [ADR index](docs/adr/README.md)
