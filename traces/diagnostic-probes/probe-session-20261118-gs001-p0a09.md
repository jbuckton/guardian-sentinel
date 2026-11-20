# OBD2 diagnostic probe session — P0A09 on GS-001

- **Date (UTC):** 2026-11-18
- **Device:** GS-001 (Raspberry Pi CM4, `mcp251x` SPI CAN), Tailscale `gs-001`
- **Unit:** Orion BMS Jr 2 — pack id `unconfirmed`, model `unconfirmed`, cell count `unconfirmed`
- **Bus:** `can0`, 500000 bit/s, state ERROR-ACTIVE (healthy)
- **Mode during session:** `can0` switched **OUT of listen-only** (transmitting). **Restored to listen-only after the session.**
- **Request ID:** `0x7E3` (Orion default) · **Response ID:** `0x7EB` (ID+8)
- **ISO-TP:** single frame `0x0X`; multi-frame first frame `0x1L LL`, flow-control sent as `0x7E3#3000000000000000` (CTS, BS=0, STmin=0)
- **Reason:** P0A09 Internal Hardware Fault present; establish what is reachable over CAN.

> All decoding below is **reverse-engineered evidence**, to be confirmed against
> Orion Jr 2 docs + the unit's config export (ADR-001/010). Not sanctioned.

## Headline result

| Question | Answer (from this session) |
|---|---|
| Is P0A09 present? | **Yes** — pending (Mode 07) **and** permanent (Mode 0A); not in confirmed list (Mode 03) at probe time |
| DTC status mask | `0x0E` = failed-this-cycle + pending + confirmed |
| **INF value** | **`0x8008`** (matches the reported "INF 8008") — see root cause below |
| "sub code 1" | **Not** literally present over CAN; the byte in that position (`0x0E`) decodes as a DTC **status mask**, not a subcode. Most likely a Utility-side occurrence/instance index; the substantive detail is the `0x8008` INF — confirm against the Utility |

## Root cause (from Orion documentation, 2026-11-20)

Per Orion's own P0A09 fault documentation, INF/subcode **`8008`** (with sibling
`8010`) = **internal watchdog redundancy fault**, which Orion documents as
occurring **when no cells are enabled (loaded) in the battery profile settings**.
Orion's prescribed check is the **cell count in the profile configuration**.

Interpretation for GS-001:

- This is a **configuration** condition, **not** a damaged pack — it maps to
  ADR-012 `fault(configuration)`, never `fault(battery)`.
- Fits the current project state: GS-001's cell population is still
  **unconfirmed** (ADR-010) and the Jr 2 config export is not yet reconciled.
  A unit powered without a fully loaded/validated profile is the expected
  trigger for `8008`.
- Weakly corroborated by the probe's `F100` cell read (seq 6): only a few
  non-zero cell values then zeros, i.e. a sparse/partial population — but the
  scaling is reverse-engineered (ADR-001/010), so this is a hint, not proof.

Still open / Utility-only:

- **Failsafe behaviour of `8008`** not confirmed from text (P0A09 overall shows
  "No Failsafe Behavior" but subcode exceptions were cut off).
- The **freeze frame** (real parameter snapshot at fault time) lives only in the
  Orion Utility DTC screen, not on CAN — save it before clearing anything.

Sources:
- Orion — DTC P0A09 Internal Hardware Fault:
  https://www.orionbms.com/faultcodes/DTC%20P0A09%20-%20Internal%20Hardware%20Fault.pdf
- Orion Jr 2 Utility manual — Internal Memory Fault (P0A09):
  https://www.orionbms.com/manuals/utility_jr/code_internal_memory_fault.html
- Orion Jr 2 Utility manual — Freeze Frame Data:
  https://orionbms.com/manuals/utility_jr/acc_freeze_frame.html
| Standard freeze frame (Mode 0x02) | Acknowledges but **stubbed** — returns identical `42 <pid> C0 00 00 13` for every PID; no real per-PID payload |
| Full environmental snapshot (cell-V/temp/current at fault time) | **Not** retrieved over CAN; appears Utility-proprietary |
| Live telemetry (Mode 0x22) | **Works** — real decoded values (e.g. SoC) |
| DTC detail incl. INF (Mode 0x17) | **Works** — `17 <DTC>` returns the detail record incl. INF |

## Exchanges (TX `0x7E3` → RX `0x7EB`)

### Mode 0x03 — confirmed/active DTCs
- TX `01 03` → RX `02 43 00` → response `43`, **count 0** (none confirmed at this instant).

### Mode 0x07 — pending DTCs
- TX `01 07` → RX `04 47 01 0A 09` → response `47`, count 1, DTC `0A 09` = **P0A09** (pending).

### Mode 0x0A — permanent DTCs
- TX `01 0A` → RX `04 4A 01 0A 09` → response `4A`, count 1, DTC `0A 09` = **P0A09** (permanent).

### Mode 0x02 — freeze frame (STUBBED)
- TX `02 00 00` → RX FF `10 08 42 00 C0 00 00 13` + CF `21 00 00` → `42 00 C0 00 00 13 00 00`.
- Walked PIDs `00 01 02 1C 1F 20` — **every one returned identical** `42 <pid> C0 00 00 13 00 00`. No real freeze-frame payload exposed via Mode 0x02.

### Mode 0x22 — live data (WORKS, real values)
- TX `22 F0 0F` (SoC) → RX `04 62 F0 0F 62` → `0x62` = 98 × 0.5 % = **~49 % SoC**.
- TX `22 F1 00` (cells 1–12) → RX multi-frame `10 1B 62 F1 00 7C 74 7C` / `21 67 7C 67 7C 6A …` / `22 …` / `23 …` — real 24-byte cell block (scaling per published PID map, provisional).
- TX `22 F0 0D` → RX `05 62 F0 0D 00 7F` → value `0x7F`.

### Mode 0x21 — extended data (WORKS, real distinct values)
- TX `21 00 00` → RX `06 61 00 C0 00 00 13 00` → supported-PID bitmask (01,02,1C,1F,20).
- TX `21 01 00` → RX `03 61 01 81` → PID01 = `0x81`.
- TX `21 02 00` → RX `04 61 02 81 00` → PID02 = `0x8100`.
- TX `21 1C 00` → RX `03 61 1C 01` → PID1C = `0x01`.
- TX `21 1F 00` → RX `04 61 1F 6B 99` → PID1F = `0x6B99`.
- TX `21 20 00` → RX `06 61 20 00 00 00 01 00` → next-bank bitmask.

### Mode 0xB2 — proprietary (exists, format unknown)
- TX `B2 00 00` and `B2 F0 0F` → RX `03 7F B2 12` → **negative, NRC 0x12** (subfunction not supported). Mode recognised; correct subfunction/format not found.

### Mode 0x17 — DTC detail / INF channel (KEY RESULT)
- TX `17 00` → RX `03 7F 17 12` → negative (NRC 0x12) for bare subfunction 0.
- TX `17 00 0A` (truncated) → RX `10 0A 57 00 0A 00 00 00` / `21 7C 67 7C 6A 00 00` → positive `57`; payload echoes query + data incl. bytes also seen in the live cell block.
- **TX `17 0A 09` (DTC P0A09 directly) → RX `10 0A 57 0A 09 0E 80 08` / `21 00 00 00 00 00 00`**
  → full 10-byte payload `57 0A 09 0E 80 08 00 00 00 00`:
  - `57` response · `0A 09` = **P0A09** · `0E` = **DTC status mask** (failed-this-cycle+pending+confirmed) · **`80 08` = INF `0x8008`**.
- Sub-record requests `17 0A 09 {00,01,02,FF}` all returned the **identical** record → the trailing record byte is ignored; this is the complete detail Mode 0x17 exposes for the DTC.

## Open items / next steps

1. **Confirm all of the above against Orion Jr 2 documentation + config export** before any of it informs the `orion_jr2` adapter (ADR-001/010).
2. **"sub code 1" unresolved** over CAN — reconcile against what the Orion Utility displays for this DTC (pull the Utility freeze frame / data snapshot and compare).
3. **Mode 0xB2** returns NRC 0x12 — unknown subfunction; the full environmental freeze frame may live here or be Utility-only.
4. These definitions, if ever used, belong behind a **new ADR amending ADR-015** (active diagnostic acquisition) — not added to the broadcast-only path.
