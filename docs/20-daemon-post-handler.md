# Spec 20 — Daemon POST handler (0x12)

## Dependencies
Spec 13 (channel msg store), Spec 16 (binary handler), Spec 19 (POST codec).

## Task
Handle POST_REQ (0x12): broadcast to channel, store, return POST_ACK (0x92).

## Deliverables
- Decode 0x12 in binary handler
- Call `mc.send_chan_msg(channel_idx, text)`
- Log to `channel_messages`
- Send 0x92

## Acceptance criteria
- [ ] Message appears on channel
- [ ] Message stored in DB
- [ ] ACK returned with ok=true
- [ ] Invalid channel returns ok=false

## Test
Send 0x12, verify msg in store + on channel, 0x92 returned.
