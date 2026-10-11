# Spec 14 — appproto header codec

## Dependencies
None.

## Task
Pure encode/decode for the 4-byte app protocol header.

## Deliverables
- `appproto.v`: `AppHeader` struct, `encode_header()`, `decode_header()`
- No IO, no daemon wiring

## Wire format
```
[0] ver      u8
[1] msg_type u8
[2] req_id   u8
[3] flags    u8
```

## Acceptance criteria
- [ ] `encode_header` returns 4 bytes
- [ ] `decode_header` round-trips correctly
- [ ] Invalid input (len < 4) returns error

## Test
`appproto_test.v`: `test_header_roundtrip()`, `test_header_short_input()`
