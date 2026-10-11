# Spec 22 — meshpipe segmentation

## Dependencies
Spec 21 (segment codec).

## Task
Split a payload into segments of max size.

## Deliverables
- `segment_payload(xfer_id, payload, max_data_size)` → []Segment

## Acceptance criteria
- [ ] Payload < max → 1 segment, first+last flags set
- [ ] Payload > max → multiple segments, correct seq/total
- [ ] Empty payload → 1 empty segment

## Test
`meshpipe_test.v`: `test_segmentation_small()`, `test_segmentation_large()`
