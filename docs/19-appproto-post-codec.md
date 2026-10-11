# Spec 19 — appproto POST codec (0x12/0x92)

## Dependencies
Spec 14 (header codec), Spec 25 (compression).

## Task
Encode/decode POST_REQ (0x12) and POST_ACK (0x92). Command codes only. **Message text compressed.**

## Deliverables
- `encode_post_req(req_id, channel_idx, text)` → bytes with 0x12
- `decode_post_req(bytes)` → (channel_idx, text)
- `encode_post_ack(req_id, ok bool)` → bytes with 0x92
- `decode_post_ack(bytes)` → ok

## Acceptance criteria
- [ ] Request carries channel_idx + text
- [ ] Ack carries success/fail flag
- [ ] Round-trip preserves all fields

## Test
`appproto_test.v`: `test_post_roundtrip()`
