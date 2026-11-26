# Orion Jr 2 Data Collection

**Purpose:** collect (A) raw CAN captures of the deployed Orion BMS Jr 2 in its normal operating states and (B) the unit's configuration export and DBC from the Orion BMS Utility.

**Who does this:** someone with physical access to the pack, the CAN capture equipment, and the Orion CANdapter.

**Allow approximately half a day:** the actual time depends on how quickly the pack can be put through its normal operating states.

## Safety rules

- The capture interface must be **listen-only**. Never transmit onto the pack's CAN bus.
- Do not use `cansend` or `canplayer` on the live pack bus.
- Use the Orion Utility only to read and export the existing configuration. **Do not write or change any BMS setting.**
- Do not unlock the BMS or automate access to it.
- Prefer to take CAN captures while the Orion Utility is disconnected. If it is connected, record that in the capture notes because its diagnostic traffic will also appear in the log.

---

## Prerequisites

- A Linux machine (the Raspberry Pi, or any laptop) with **can-utils**: `sudo apt install can-utils`
- A **listen-only-capable CAN interface** wired to the pack's CAN bus. *No transmit.*
- The Orion **CANdapter** (USB↔CAN) and the **Orion Jr 2 Utility** ([Windows](https://www.orionbms.com/downloads/orionjr2_utility_stable.exe) / [Linux](https://www.orionbms.com/downloads/orionjr2_utility_stable.zip)) for Part B.
- Known **CAN baud rate** (Jr 2 default **500 kbps**; confirm — if frames don't appear, try 250k / 125k / 1M).
- **Confirm before you start:** the pack designer must provide the pack's cell count. Record that confirmed count, the pack model (`48-10` or `48-20`), and the CAN node ID of the pack's single Orion Jr 2. Do not infer the cell count from captured traffic or the profile name.

---

## Part A — Raw CAN capture (no decoding needed)

Capture everything raw. Do **not** interpret or alter the data in the field.

### Choose one capture method

Use **Option A** when the capture script is available. Use **Option B** only as the manual fallback. Do not perform both options for the same session.

#### Option A — Capture with the script (preferred)

1. On the capture computer, confirm `ip`, `candump`, and `timeout` are installed, root access is available (normally through `sudo`), and the listen-only-capable CAN interface is connected.
2. From the repository root, run:

   ```bash
   ./scripts/collect_can_trace.sh
   ```

3. Answer the prompts and leave the capture running for the requested duration. The script configures `can0` in listen-only mode, refuses to continue if listen-only is not reported, captures data frames (and error frames when supported), records before/after interface counters, and writes the `.meta.yaml` sidecar.
4. Repeat the script for each applicable operating state in the shared list below.

#### Option B — Capture manually

1. Configure the interface and confirm that it reports `LISTEN-ONLY` and the expected bitrate:

   ```bash
   sudo ip link set can0 down
   sudo ip link set can0 type can bitrate 500000 listen-only on berr-reporting on
   sudo ip link set can0 up
   ip -details link show can0
   ```

   If the controller does not support listen-only mode, stop and use the approved listen-only-capable interface.

2. Save the interface statistics before the capture:

   ```bash
   ip -details -statistics link show can0
   ```

3. Record one 2–5 minute session for the selected operating state. Use a longer session if broadcasts are slow. Press `Ctrl-C` to stop and note the filename printed by `candump`:

   ```bash
   candump -l 'can0,0:0,#FFFFFFFF'
   ```

   If the interface does not support error-frame reporting, record that limitation and use `candump -l can0` instead.

4. Save the interface statistics again after the capture:

   ```bash
   ip -details -statistics link show can0
   ```

5. Create `<capture-name>.log.meta.yaml` and record:

   - pack identifier and model
   - designer-confirmed cell count
   - Orion Jr 2 serial number and CAN node ID
   - OBD2 ECU ID and thermistor details, if known
   - operating state
   - capture date, time, duration, and whether the computer clock was synchronised
   - CAN bitrate, interface, and capture hardware
   - confirmation that listen-only mode was active
   - whether the Orion Utility was connected
   - operator name and any relevant notes
   - filenames of the before/after interface statistics

6. Repeat these steps for each applicable operating state in the shared list below.

### Operating states to collect with either option

- [ ] **idle / rest** (contactors closed, no current)
- [ ] **charging**
- [ ] **discharging** (under load)
- [ ] **any safely reproducible alarm/fault** state (e.g. a benign warning) — do **not** force unsafe conditions
- [ ] **power-up / boot** of the BMS if you can catch it

> Do **not** replay these logs onto the live pack bus. `canplayer` transmits — it's for later bench/loopback use only.

---

## Part B — Configuration export + DBC (one Jr 2 per pack)

The export provides the message IDs, scaling, and configured cell and thermistor layout. **Read/export only.**

1. Connect the **CANdapter** (USB) to the laptop and to the CAN bus; set the Utility's baud to match the BMS.
2. Open the **Orion Jr 2 Utility**, connect to the unit, and **read** its current configuration.
3. **Export the CAN communication matrix as a DBC file.** The configured matrix may differ between units, so use the export from this BMS.
4. **Save the full profile/settings file** for the unit.
5. Record the **firmware version** shown in the Utility.
6. Confirm the export belongs to the pack's single Orion Jr 2 and label it with the pack identifier/model.
7. Record which configured periodic broadcasts contain per-cell voltages, temperatures, pack voltage/current, state of charge, and status/alarm flags. Also record the configured OBD2 ECU ID.

---

## Deliverables (hand back)

- [ ] `*.dbc` — CAN communication matrix export for the pack's Orion Jr 2
- [ ] Orion **profile/settings** file for the pack's Orion Jr 2
- [ ] **Firmware version** of the Orion Jr 2
- [ ] `candump-*.log` files + their `*.meta.yaml` sidecars, covering the states above
- [ ] Before/after CAN interface statistics for each capture
- [ ] Photos of the unit label(s) and CAN wiring/tap
- [ ] Written confirmation from the pack designer of the **pack cell count**, plus the pack model (`48-10` or `48-20`), Orion Jr 2 CAN node ID, and thermistor count/placement
- [ ] Written list of which configured periodic broadcasts contain per-cell voltages, temperatures, pack voltage/current, state of charge, and status/alarm flags, plus the configured OBD2 ECU ID
