# Finding: gs-001 CAN adapter does not support error-frame reporting

**Date:** 2026-11-20
**Device:** gs-001 (`mp`, Tailscale `100.118.146.20`)
**Relates to:** Phase 2 exit criteria (capture CAN state-change / error events) and
ADR-004 in-band health ordering.
**Severity:** Capability gap for in-band CAN error capture. **Not** a CAN-bus safety
breach. **Not** a G4 listen-only failure — listen-only works (see below).
**Status:** Open — controller does not expose bus-error reporting over SocketCAN.

> **Correction (2026-11-20):** an earlier version of this note claimed the adapter did
> not support **listen-only** mode and recorded it as a G4 gap. That was wrong. The
> `RTNETLINK answers: Operation not supported` seen during the capture came from the
> **`berr-reporting on`** call, not `listen-only on`. Listen-only was set successfully
> and verified — the capture-time interface state shows `can <LISTEN-ONLY>`, and the
> collection script refuses to capture unless the controller reports listen-only. The
> sidecar's `listen_only_confirmed: true` was correct and has been restored.

## What was observed

During the 2026-11-20 field capture
(`candump-20261120T062350Z-0-idle.log`, 75,531 frames / 180 s), the collection script
configured `can0` and reported:

```
Configuring can0 at 500000 bit/s in listen-only mode...
RTNETLINK answers: Operation not supported
Warning: can0 does not support CAN error-frame reporting; continuing in listen-only mode.
Recording can0 for 180 seconds. No CAN frames will be transmitted.
```

Sequence of the two `ip link` calls in the script explains it:

1. `ip link set can0 type can bitrate 500000 listen-only on` — **succeeded**. Under
   `set -euo pipefail` a failure here would have aborted the run; it did not.
2. `ip link set can0 type can berr-reporting on` — **failed** with
   `Operation not supported`, producing the RTNETLINK line and the warning. This is the
   only unsupported feature.

Capture-time interface state (from the capture's `*.can-stats-before.txt`, and still
current):

```
can <LISTEN-ONLY> state ERROR-ACTIVE restart-ms 0
      bitrate 500000 sample-point 0.875
```

So `CAN_CTRLMODE_LISTENONLY` is supported and active; `CAN_CTRLMODE_BERR_REPORTING`
is not.

## Why it matters

- **Listen-only (G4):** satisfied at the controller for this adapter — good. Zero
  transmission (ADR-009/ADR-015) continues to hold, and `candump` is a passive reader.
- **Error-frame reporting:** without `berr-reporting`, the controller does not deliver
  bus-error frames to SocketCAN, so the `#FFFFFFFF` error-mask in the candump filter is
  inert and **in-band CAN error events are not captured**. This weakens the Phase-2
  exit criterion "capture CAN state-change and error events alongside frames to validate
  in-band health ordering" and the ADR-004 ordering validation. Controller/bus **state**
  changes (e.g. ERROR-ACTIVE → ERROR-PASSIVE → BUS-OFF) are still observable via
  `ip -details -statistics link show` polling / netlink, but per-frame error detail is
  not available on this adapter.

## Recommended actions

1. **Record the limitation per capture.** The collection script now writes
   `error_frame_reporting: true|false` to the sidecar (fixed 2026-11-20), so traces made
   on this adapter are explicitly marked as lacking in-band error frames.
2. **Confirm the fitted controller.** Record the exact CAN controller/transceiver on
   gs-001 and check whether `berr-reporting` is a driver limitation or a hardware one.
3. **Weigh it in G4 hardware selection.** Error-frame reporting (`CAN_CTRLMODE_BERR_REPORTING`)
   should be a desirable criterion alongside listen-only and isolation, so in-band error
   capture is available where the controller supports it. This does not block listen-only
   compliance, which the current adapter already meets.
4. **Validate the state-change path.** Since per-frame error frames are unavailable here,
   verify that controller/bus state transitions are still captured by the statistics/netlink
   path for the Phase-2 health-ordering check.

## Evidence

- Capture console output (above), 2026-11-20 `sudo bash collect_can_trace.sh` session.
- `candump-20261120T062350Z-0-idle.can-stats-before.txt` — `can <LISTEN-ONLY>` at capture time.
- Retagged sidecar: `candump-20261120T062350Z-0-idle.log.meta.yaml`
  (`listen_only_confirmed: true`, `error_frame_reporting: false`).
- Script fix: `scripts/collect_can_trace.sh` now derives `listen_only_confirmed` from the
  interface state and records `error_frame_reporting`.
