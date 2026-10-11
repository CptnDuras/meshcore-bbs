# Spec 17 — appproto HISTORY codec (0x10/0x90)

## Dependencies
Spec 14 (header codec), Spec 25 (compression).

## Task
Encode/decode HISTORY_REQ (0x10) and HISTORY_RES (0x90). Command codes only — no words over wire. **Response payload compressed.**

## Deliverables
- `encode_history_req(req_id, channel_idx, count)`
- `decode_history_req(bytes)` → (channel_idx, count)
- `encode_history_res(req_id, messages[])`
- `decode_history_res(bytes)` → messages[]

## Message record format
```
[0-3] ts      u32 LE
[4]   who_len u8
[5..] who     utf8
      txt_len u8
      txt     utf8
```

## Acceptance criteria
- [ ] Request encodes channel_idx + count
- [ ] Response packs multiple messages
- [ ] Round-trip preserves all fields

## Test
`appproto_test.v`: `test_history_roundtrip()`
