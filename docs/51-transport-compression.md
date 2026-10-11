# Spec 51 — Compression applied at transport layer

## Dependencies
Spec 25 (wire compression), Spec 21-23 (meshpipe).

## Concept
Compression is **not optional per-opcode** — it's applied uniformly at the meshpipe layer for all multi-frame transfers and at the single-frame layer for all payloads >20 bytes.

## Rules
1. **Single frame, payload >20 bytes**: compress, set flag
2. **Single frame, payload ≤20 bytes**: skip (overhead not worth it)
3. **Multi-frame (meshpipe)**: compress entire payload before segmentation
4. **Already-compressed data** (images, pre-zipped): wire compression still attempted, skipped if no gain

## Implementation
- `send_datagram(opcode, payload)`:
  - if len > 20: try compress
  - if compressed < original: use compressed, set flag
  - else: send raw
- `recv_datagram()`:
  - check flag, decompress if set
- meshpipe: compress before `segment_payload()`, decompress after `reassemble()`

## Acceptance criteria
- [ ] All opcodes go through compression layer
- [ ] Small payloads (<20B) skip compression
- [ ] Text messages compress ~50-70%
- [ ] Pre-compressed data doesn't bloat
- [ ] No opcode bypasses compression check

## Test
Send various payload sizes/types, verify compression applied correctly.
