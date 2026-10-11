# Spec 23 — meshpipe reassembly

## Dependencies
Spec 21 (segment codec).

## Task
Reassemble segments into original payload.

## Deliverables
- `Reassembler` struct (buffers by xfer_id)
- `reassembler.add(segment)` → ?complete_payload

## Acceptance criteria
- [ ] Returns payload when all segments received
- [ ] Out-of-order segments handled
- [ ] Duplicate segments ignored
- [ ] Returns none until complete

## Test
`meshpipe_test.v`: `test_reassembly_in_order()`, `test_reassembly_out_of_order()`
