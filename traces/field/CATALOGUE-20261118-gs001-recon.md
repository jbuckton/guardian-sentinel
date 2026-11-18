# gs-001 CAN broadcast catalogue — recon capture 2026-11-18

**Source:** `candump-20261118T032236Z-gs001-recon.log` (60 s, read-only, `can0` @ 500 kbit/s).
**Status:** Stage-0 reconnaissance only. Cataloguing IDs / rates / DLCs is permitted now
(`traces/FORMAT.md`); **no physical meaning or scaling is assigned** — that waits for the
unit's exported DBC (ADR-001/010). Everything under "hypothesis" below is a lead to verify
against the config export, **not** a finding.

## Summary
- **419.6 fps** total over 59.99 s (25,175 frames), **8 unique CAN IDs**.
- Dominated by three 125 Hz (8 ms) messages: `00A`, `00B`, `6B0` (= 375 fps).
- Nominal load figure for Phase 4 drop-budget seeding. **Peak not characterised** — this was
  a single steady-state window; charging/discharging/alarm states not captured.

## ID catalogue (observed)

| CAN ID | fmt | DLC | count | fps | period (ms) | jitter (ms) | observed payload behaviour |
|--------|-----|-----|-------|-----|-------------|-------------|----------------------------|
| `00A` | std | 8 | 7499 | 125.0 | 8.00 | 0.02 | static `0004000000000000` |
| `00B` | std | 8 | 7499 | 125.0 | 8.00 | 0.02 | static `7F00000000000000` |
| `080` | std | 4 | 600 | 10.0 | 100.0 | 0.56 | b0 5–6, b1 32–35, b3 157–161 vary |
| `6B0` | std | 8 | 7500 | 125.0 | 8.00 | 0.06 | b1 8–9, b7 37–38 vary |
| `6B1` | std | 8 | 577 | 9.6 | 104.0 | 0.13 | static `0064003C17150085` |
| `1838F380` | ext(29) | 8 | 600 | 10.0 | 100.0 | 0.31 | **multiplexed**: b1 & b3 index 0–33, b2 21–23, b4 20–21, b7 3–6 |
| `1839F380` | ext(29) | 8 | 600 | 10.0 | 100.0 | 0.29 | b1 20–21, b6 3–6, b7 192–194 vary |
| `18EEFF80` | ext(29) | 8 | 300 | 5.0 | 200.0 | 1.82 | static `F30080F300401E90` |

## Hypotheses to verify against the DBC / config export (NOT findings)
- The three 29-bit IDs are **J1939-shaped**. `18EEFF80` matches the form of a J1939
  **Address-Claimed** PGN (0xEE00) from source address `0x80` — consistent with an Orion
  J1939 broadcast, but **unconfirmed**.
- `1838F380` is a **multiplexed/indexed** message: a byte cycles through index **0–33**
  (0x00–0x21), one index every ~2.6 s. This is the classic shape of a per-element indexed
  broadcast (e.g. per-cell or per-thermistor). **The index range is NOT the cell count** and
  must not be read as such (ADR-010) — it is a lead to reconcile with the configuration export.
- `080`, `6B0`, `6B1`, `00A`, `00B` are plausibly configured 11-bit broadcasts; meaning unknown.

## Caveats / provenance
- **Not listen-only:** `can0` was in normal mode during capture (candump still only reads).
- **Facts unconfirmed:** pack model, cell count, Jr 2 serial/node ID, thermistor layout all
  pending the designer + Orion Utility export (Part B, onsite).
- **Coverage incomplete:** one steady-state window only; no charging/discharging/alarm/boot
  states, so broadcast-coverage sign-off (Phase 2 exit / ADR-015) is **not** met by this capture.
- **Tooling bug found:** the `0~0,#FFFFFFFF` filter in `collect_can_trace.sh` and
  `data-collection.md` Option B is inverted and captures **nothing**; must be fixed before a
  recorded capture or every trace will be empty.
