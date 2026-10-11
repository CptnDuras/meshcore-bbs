# Spec 18 — Daemon HISTORY handler (0x10)

## Dependencies
Spec 13 (channel msg store), Spec 16 (binary handler), Spec 17 (HISTORY codec).

## Task
Handle HISTORY_REQ (0x10): query store, return HISTORY_RES (0x90).

## Deliverables
- Decode 0x10 in binary handler
- Call `store.recent_channel_msgs(count)`
- Encode + send 0x90

## Acceptance criteria
- [ ] Returns last N messages from store
- [ ] Empty store returns empty response (not error)
- [ ] req_id echoed correctly

## Test
Post 5 channel msgs, send 0x10 (count=3), verify 0x90 returns 3 in order.
