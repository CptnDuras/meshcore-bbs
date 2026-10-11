# Spec 29 — App: Send PING, receive PONG

## Dependencies
Spec 27 (BLE pair), Spec 28 (Dart header codec), Spec 16 (daemon PING handler).

## Task
App sends PING over channel data, receives PONG from meshbbs.

## Deliverables
- Button/action to send PING
- Display PONG response

## Acceptance criteria
- [ ] PING sent via `send_channel_data`
- [ ] PONG received and displayed
- [ ] req_id matches

## Test
Manual: tap ping, see pong confirmation.
