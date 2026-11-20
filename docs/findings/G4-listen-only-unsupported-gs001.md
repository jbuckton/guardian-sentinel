# Finding: gs-001 CAN adapter does not support listen-only mode (G4 gap)

**Date:** 2026-11-20
**Device:** gs-001 (`mp`, Tailscale `100.118.146.20`)
**Gate:** G4 — CAN interface hardware (still **Open**, `docs/implementation-plan.md`)
**Severity:** Blocking for G4 sign-off; **not** a CAN-bus safety breach for captures taken so far.
**Status:** Open — hardware selection/configuration change required.

## What was observed

During the 2026-11-20 field capture
(`traces/.../candump-20261120T062350Z-0-idle.log`, 75,531 frames / 180 s), the
collection script attempted to place `can0` into listen-only mode and the kernel
rejected it:

```
Configuring can0 at 500000 bit/s in listen-only mode...
RTNETLINK answers: Operation not supported
Warning: can0 does not support CAN error-frame reporting; continuing in listen-only mode.
Recording can0 for 180 seconds. No CAN frames will be transmitted.
```

Two separate adapter limitations are exposed:

1. **Listen-only (silent / restricted-operation) mode is unsupported.** `ip link set
   can0 type can listen-only on` returns `Operation not supported`. The controller
   will not suppress acknowledgement/error-active signalling in hardware.
2. **CAN error-frame reporting is unsupported.** The `#FFFFFFFF` error mask in the
   candump filter is inert, so controller error/state events are not captured in-band
   (relevant to the Phase-2 exit criterion on CAN state-change / error capture, and to
   the ADR-004 in-band health ordering).

The script's generated sidecar recorded `listen_only_confirmed: true`, which was
**wrong** — it reflected the attempt, not the result. The affected capture's sidecar
was retagged recon/unconfirmed on 2026-11-20 with `listen_only_confirmed: false`.

## Why it matters

- **G4 selection criterion.** The plan requires an isolated interface with
  **listen-only enforcement at the controller** (`docs/implementation-plan.md` G4;
  ADR-015 makes zero-transmission a hard requirement). The current adapter cannot
  enforce listen-only in hardware, so it does **not** satisfy G4 as written.
- **Not a breach of ADR-009/ADR-015 for captures to date.** `candump` is a passive
  reader and transmitted no frames. However, without controller-level listen-only the
  adapter is *capable* of ACK/error-frame transmission if any process ever opened the
  socket in normal TX mode. The read-only guarantee currently depends on operator
  discipline (candump only), not on the hardware — which is exactly what G4 is meant
  to remove.
- **Missing in-band health signal.** No error-frame capture weakens the Phase-2/ADR-004
  validation of CAN state-change and error ordering.

## Recommended actions

1. **Do not rely on software listen-only for GS captures.** Treat the hardware as
   non-compliant with G4 until replaced/reconfigured; keep captures candump-only and
   tag them accordingly.
2. **Re-run G4 hardware selection** for an interface whose controller supports
   restricted-operation (listen-only) mode and error-frame reporting (e.g. a
   controller/transceiver combination that exposes `CAN_CTRLMODE_LISTENONLY` and
   `CAN_CTRLMODE_BERR_REPORTING` via SocketCAN), with galvanic isolation, validated
   against the Jr 2's configured bus parameters from the configuration export.
3. **Record the exact adapter** currently fitted to gs-001 (controller chip,
   transceiver, carrier) so the G4 shortlist can exclude it and the limitation is
   traceable.
4. **Fix the collection script** so `listen_only_confirmed` reflects the actual result
   of the `ip link set ... listen-only on` call (fail or warn loudly, and write
   `false` on failure) rather than the intent.

## Evidence

- Capture output (above) from `sudo bash collect_can_trace.sh`, 2026-11-20 session.
- Retagged sidecar: `candump-20261120T062350Z-0-idle.log.meta.yaml`
  (`listen_only_confirmed: false`, `error_frame_reporting: false`).
- G4 definition: `docs/implementation-plan.md` (decision-gates table) and
  `docs/adr/ADR-015-broadcast-only-acquisition.md`.
