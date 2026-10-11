# Spec 15 — appproto PING/PONG codec

## Dependencies
Spec 14 (header codec).

## Task
Add PING (0x1F) and PONG (0x9F) opcode encode/decode.

## Deliverables
- `encode_ping(req_id)` → header bytes
- `encode_pong(req_id)` → header bytes
- `is_ping()`, `is_pong()` helpers

## Acceptance criteria
- [ ] PING encodes to 4 bytes, msg_type=0x1F
- [ ] PONG encodes to 4 bytes, msg_type=0x9F
- [ ] Round-trip: encode→decode preserves req_id

## Test
`appproto_test.v`: `test_ping_pong_roundtrip()`
