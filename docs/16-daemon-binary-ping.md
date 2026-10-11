# Spec 16 — Daemon binary handler (PING only)

## Dependencies
Spec 15 (PING/PONG codec).

## Task
Subscribe to `.channel_data_recv`; respond to PING with PONG.

## Deliverables
- New subscription in `main.v` for `.channel_data_recv`
- Filter on `data_type == 0xBB01`
- Decode header; if PING, send PONG via `send_channel_data`

## Acceptance criteria
- [ ] Handler ignores other `data_type` values
- [ ] PING request returns PONG with same `req_id`
- [ ] Text mode unaffected (regression: `HELP` still works)

## Test
Manual: send PING from test script, verify PONG returned.
Regression: `v test bbs/` passes.
