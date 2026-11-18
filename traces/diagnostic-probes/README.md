# Diagnostic probes — ACTIVE (transmitted) CAN exchanges

> **These are NOT broadcast-only captures.** The frames here were produced by a
> one-off **manual diagnostic session** in which Guardian's Pi **transmitted**
> OBD2 request frames (`0x7E3`) to the Orion Jr 2 and recorded its responses
> (`0x7EB`). This is exactly the request/response traffic that **ADR-015
> (broadcast-only acquisition)** says Guardian does **not** do in normal
> operation. These traces are kept **separate from `traces/field/`** (the
> listen-only broadcast library that feeds the replay test harness) so they can
> never be mistaken for broadcast-only evidence or fed to the decoder as if the
> adapter had produced them.

## Status of the decoding — evidence, not ground truth

Every mode/PID/field interpretation in these files was **reverse-engineered from
one live unit** during the session. Per **ADR-001 / ADR-010 (never invent
message definitions)** this is **evidence to confirm against Orion Jr 2
documentation and the unit's configuration export** — it is **not** yet a
sanctioned definition and must not be hard-coded into `orion_jr2` until
confirmed from an authoritative source.

## When/why this was done

A P0A09 (Internal Hardware Fault) was present on the deployed unit. The goal was
to establish **what diagnostic data is reachable over CAN** (DTC state, freeze
frame, the `INF`/`sub code` detail) without the Orion Utility. The interface was
deliberately switched **out of listen-only** for the session and **restored to
listen-only afterwards**.

## Files

- `probe-session-20261118-gs001-p0a09.md` — annotated record: every TX request,
  the RX response bytes, and the decode.
- `probe-session-20261118-gs001-p0a09.jsonl` — machine-readable exchanges.
- `probe-session-20261118-gs001-p0a09.meta.yaml` — metadata sidecar.

## Reconstruction note

The `.jsonl` / `.md` were reconstructed from the session's observed exchanges.
A clean live re-capture (TX+RX, epoch timestamps) was **not** retaken because
the interface had already been returned to listen-only and re-transmitting purely
to capture was judged not worth reopening the bus. Response bytes are recorded
exactly as observed; request bytes are exactly as sent.
