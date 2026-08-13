# Runbook / Hand-over Task: Orion Jr 2 Data Collection

**Purpose:** collect the two inputs Guardian Sentinel is blocked on — (A) a **raw CAN capture** of the deployed Orion BMS Jr 2 in its normal operating states, and (B) the unit's **configuration export + DBC** from the Orion BMS Utility.
**Who does this:** field / integration engineer with physical access to the pack and the Orion CANdapter.
**Time:** ~half a day on site (capture windows depend on getting the pack through its states).
**Golden rule — read-only:** the Guardian capture interface is **listen-only**; never transmit on the pack's CAN bus. Reading/exporting config with the Orion Utility is fine, but **do not write or change any BMS setting.** **Never unlock the BMS over CAN from any tool other than the Orion Utility, and never automate it:** unlocking stops all normal CAN broadcasts and **disengages every BMS-controlled relay** until re-lock/restart (see ADR-015). Note the Utility's own connection uses OBD2 polling — expect its diagnostic request/response traffic (default 0x7E3/0x7EB) to appear in any capture taken while the Utility is connected; annotate those windows in the meta sidecar.

**Coverage check before leaving site (ADR-015):** in the Utility, confirm the unit's **configured periodic broadcasts** cover every signal the MVP rules need (per-cell voltages, temperatures, pack voltage/current, SoC, status/alarm flags). Guardian is broadcast-only — anything not broadcast is invisible to it. Record the configured **OBD2 ECU ID** as well (it is profile-configurable).

Related docs: what the data feeds and why → [`profiles/SOURCING.md`](../../profiles/SOURCING.md); capture file format → [`traces/FORMAT.md`](../../traces/FORMAT.md); decisions → [`docs/adr/`](../adr/README.md) (esp. ADR-001, ADR-010).

---

## Prerequisites

- A Linux machine (the Raspberry Pi, or any laptop) with **can-utils**: `sudo apt install can-utils`
- A **listen-only-capable CAN interface** wired to the pack's CAN bus (isolated tap — decision gate G4). *No* transmit.
- The Orion **CANdapter** (USB↔CAN) and the **Orion Jr 2 Utility** ([Windows](https://www.orionbms.com/downloads/orionjr2_utility_stable.exe) / [Linux](https://www.orionbms.com/downloads/orionjr2_utility_stable.zip)) for Part B.
- Known **CAN baud rate** (Jr 2 default **500 kbps**; confirm — if frames don't appear, try 250k / 125k / 1M).
- **Answer these before you start** (from the integrator): how many Jr 2 units are on this pack, and what are their CAN node IDs? (The spec sheet lists ~16 cells/unit, so a 32- or 64-cell pack likely means **multiple units** — capture each.)

---

## Part A — Raw CAN capture (no decoding needed)

We capture *everything* raw now; decoding happens later once the DBC (Part B) is in hand. Do **not** interpret values in the field.

### 1. Bring up the interface, listen-only

```bash
sudo ip link set can0 type can bitrate 500000 listen-only on
sudo ip link set can0 up
ip -details link show can0        # confirm "LISTEN-ONLY" and bitrate 500000
```

If the controller doesn't support `listen-only`, bring it up without that flag **but transmit nothing** (never run `cansend`/`canplayer` on the live bus).

### 2. Record a session per operating state

Run one capture per state so they're separable. `candump -l` writes a timestamped, replayable log file (`candump-YYYY-MM-DD_HHMMSS.log`):

```bash
candump -l can0                   # Ctrl-C to stop; note the filename it prints
```

Capture, ideally 2–5 min each (longer for slow broadcasts):

- [ ] **idle / rest** (contactors closed, no current)
- [ ] **charging**
- [ ] **discharging** (under load)
- [ ] **any safely reproducible alarm/fault** state (e.g. a benign warning) — do **not** force unsafe conditions
- [ ] **power-up / boot** of the BMS if you can catch it

To also capture CAN **error frames** and bus health in the same log, add the error mask and enable reporting (verify against `man candump` for your can-utils version):

```bash
sudo ip link set can0 type can bitrate 500000 listen-only on berr-reporting on
candump -l 'can0,0~0,#FFFFFFFF'   # data frames + error frames
```

Snapshot the interface error counters a few times per session:

```bash
ip -details -statistics link show can0
```

### 3. Write a metadata sidecar per capture

Next to each `.log`, save `<same-name>.meta.yaml` (template in [`traces/FORMAT.md`](../../traces/FORMAT.md)): date/time, unit(s) + node IDs, operating state, bitrate, capture hardware, and free-text notes (what the pack was doing, anything unusual).

> Do **not** replay these logs onto the live pack bus. `canplayer` transmits — it's for later bench/loopback use only.

---

## Part B — Configuration export + DBC (per unit)

This is the authoritative source of every message ID, scaling, and the real cell/thermistor layout (ADR-010). **Read/export only.**

1. Connect the **CANdapter** (USB) to the laptop and to the CAN bus; set the Utility's baud to match the BMS.
2. Open the **Orion Jr 2 Utility**, connect to the unit, and **read** its current configuration.
3. **Export the CAN communication matrix as a DBC file.** (There is no standard matrix — the export is the only source of truth; see [Viewing the CANBUS Communication Matrix](https://www.orionbms.com/downloads/misc/viewing_canbus_communication_matrix.pdf) and [Editing Custom CANBUS Messages](https://www.orionbms.com/downloads/misc/editing_canbus_messages.pdf).)
4. **Save the full profile/settings file** for the unit.
5. Record the **firmware version** shown in the Utility.
6. **Repeat for every Jr 2 unit** on the pack.

Reference manuals: [Wiring & Installation](https://www.orionbms.com/manuals/pdf/jr2_wiring_manual.pdf), [Operation](https://www.orionbms.com/manuals/pdf/jr2_operational_manual.pdf), [Spec sheet](https://www.orionbms.com/downloads/documents/orionjr2_specifications.pdf).

---

## Deliverables (hand back)

- [ ] `*.dbc` — CAN communication matrix export, **one per unit**
- [ ] Orion **profile/settings** file, one per unit
- [ ] **Firmware version** of each unit
- [ ] `candump-*.log` files + their `*.meta.yaml` sidecars, covering the states above
- [ ] `ip -s link` counter snapshots (paste into the session notes)
- [ ] Photos of the unit label(s) and CAN wiring/tap
- [ ] Written answers: **how many units / node IDs**, and the **actual cell count + thermistor count/placement** per the export (reconciles the provisional 32/64-cell `48-10`/`48-20` profiles)
- [ ] **Broadcast-coverage result** — the written outcome of the coverage check above: which MVP-required signals (per-cell voltages, temperatures, pack voltage/current, SoC, status/alarm flags) **are** and **are not** present in the unit's configured periodic broadcasts, plus the configured OBD2 ECU ID. This is the **ADR-015 go/no-go for Phase 2 sign-off**: any required signal not broadcast must be added to the profile at commissioning (Guardian never polls), or it reopens ADR-015 via a new ADR.

## Done when

Every ADR-010 profile field can be filled from the export with a citation (see [`profiles/SOURCING.md`](../../profiles/SOURCING.md)), and the raw captures replay cleanly through the (future) decoder — i.e. Phase 2 exit criteria in [`docs/implementation-plan.md`](../implementation-plan.md) are met.
