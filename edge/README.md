# edge/

Future home of the two edge processes (ADR-003). **No source code yet — documentation phase only.**

- `guardian_can/` — SocketCAN ingestion process (ADR-003, ADR-004, ADR-005)
- `guardian_core/` — decoding, state, rules, persistence, uplink, local API
  - `adapters/orion_jr2/` — sole MVP BMS adapter (ADR-001): `decoder.py`, `profile.py`, `validation.py`, `messages.py`
