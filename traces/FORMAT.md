# Trace / Capture Format

Two capture stages, decoupled so **raw capture can start before any profile or decoder exists** (ADR-004/005). Iteration one records everything and decodes nothing.

## Stage 0 — field capture (`candump` logs)

The immediate, zero-code format: can-utils log files from [`docs/runbooks/data-collection.md`](../docs/runbooks/data-collection.md).

- File: `candump-YYYY-MM-DD_HHMMSS.log`, lines like `(1786000000.123456) can0 18FF50E5#01A2B3...` — epoch timestamp, interface, `ID#DATA` (error frames included when captured with the error mask).
- Each log has a sidecar `*.meta.yaml`:

```yaml
schema_version: 1
capture: candump-2026-11-03T141530Z-pack-01-charging.log
captured_at_utc: "2026-11-03T14:15:30Z"
pack_id: pack-01
pack_model: 48-10
designer_confirmed_cell_count: 32
orion_jr2_serial: "JR2-12345"
can_node_id: "0x01"
obd2_ecu_id: unknown
thermistors: "10; locations supplied by pack designer"
state: charging          # startup | idle | charging | discharging | alarm
bitrate: 500000
interface: can0
hardware: "Raspberry Pi CM4 + Waveshare CM4 PoE 4G carrier + <CAN adapter>"
listen_only_confirmed: true
utility_connected: false
capture_duration_seconds: 180
ntp_synchronised: "yes"
operator: "Sam"
can_stats_before: candump-2026-11-03T141530Z-pack-01-charging.can-stats-before.txt
can_stats_after: candump-2026-11-03T141530Z-pack-01-charging.can-stats-after.txt
notes: "Approximately 60% SoC; charging normally"
```

The preferred way to create this file is [`scripts/collect_can_trace.sh`](../scripts/collect_can_trace.sh); manual editing is only the fallback.

These logs are **evidence and test input**, never edited. They are not decoded in the field (ADR-001/010: no invented scaling).

## Stage 1 — ingestion-log envelope (replayable)

The production format (ADR-004): the same records wrapped in the versioned typed envelope so replay and live share one decoder path (ADR-005). A **raw CAN frame** event carries the **undecoded** payload — no battery interpretation until the DBC lands.

Envelope fields (per ADR-004): schema version · session id (`boot_id`+nonce / UUIDv7) · per-session sequence · event type · source interface · wall-clock receipt time + confidence · monotonic receipt time · payload. Frame payload = `can_id`, `dlc`, `data` bytes, flags (extended/error).

### `candump` → envelope conversion

A small converter reads a Stage-0 log and emits Stage-1 events: parse `(ts) iface id#data`, assign a session id for the file (+ discontinuity if timestamps jump), assign sequence in arrival order, set wall-clock = log ts (confidence `unsynchronised` unless the capture clock was NTP-synced), and carry the raw frame verbatim. Error-frame lines become CAN-error events. No decode step. (Converter lands in Phase 2/3; the format is fixed now so captures taken today convert later without loss.)

## What turns raw into decoded (later)

Phase 3: load the unit's exported **DBC** (SOURCING.md) into the `orion_jr2` decoder via `cantools`, replay Stage-1 events through it → normalised telemetry. Cataloguing CAN IDs / rates / DLCs from Stage-0 is allowed now; assigning physical meaning/scaling waits for the DBC.
