# Spec 13 — Persist channel messages in store

## Dependencies
None.

## Task
Add `channel_messages` table; log every channel msg the daemon sees.

## Deliverables
- `ChannelMessage` model in `models.v`
- `log_channel_msg()` + `recent_channel_msgs(limit)` in `store.v`
- Call from existing `chan_cb` in `main.v`

## Acceptance criteria
- [ ] Table created on migrate
- [ ] Channel msgs logged with ts, sender, text
- [ ] `recent_channel_msgs(10)` returns last 10
- [ ] Unit test passes

## Test
`v test bbs/store_test.v` — add `test_channel_messages()`
