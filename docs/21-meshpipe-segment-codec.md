# Spec 21 — meshpipe segment codec

## Dependencies
None.

## Task
Pure encode/decode for meshpipe segment header.

## Deliverables
- `meshpipe.v`: `SegmentHeader` struct
- `encode_segment(xfer_id, seq, total, flags, data)`
- `decode_segment(bytes)` → (header, data)

## Wire format
```
[0]   xfer_id u8
[1-2] seq     u16 LE
[3-4] total   u16 LE
[5]   flags   u8
[6..] data
```

## Acceptance criteria
- [ ] Encodes header + data
- [ ] Decodes header + data
- [ ] Round-trip preserves all fields

## Test
`meshpipe_test.v`: `test_segment_roundtrip()`
