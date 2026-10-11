# Spec 24 — meshpipe ACK codec

## Dependencies
None.

## Task
Encode/decode selective ACK frames.

## Deliverables
- `encode_ack(xfer_id, received_bitmap)`
- `decode_ack(bytes)` → (xfer_id, bitmap)
- `missing_seqs(bitmap, total)` → []seq

## Acceptance criteria
- [ ] Bitmap encodes which seqs received
- [ ] `missing_seqs` returns gaps
- [ ] Round-trip preserves bitmap

## Test
`meshpipe_test.v`: `test_ack_roundtrip()`, `test_missing_seqs()`
