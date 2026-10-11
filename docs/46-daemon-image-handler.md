# Spec 46 — Daemon image handler

## Dependencies
Spec 45 (image codec), Spec 21-23 (meshpipe), Spec 40 (server sync).

## Task
Handle incoming images: receive, store, sync, serve.

## Deliverables
- Handle 0x14 (IMAGE_MSG)
- Reassemble via meshpipe if multi-frame
- Store in `images` table (hash, data, metadata)
- Sync to other servers
- Serve on request

## Storage
```sql
images:
  id, hash (content-addressed), channel_idx,
  sender, ts, width, height, img_type, data
```

## Acceptance criteria
- [ ] Image received and stored
- [ ] Hash computed for dedup
- [ ] Synced to peer servers
- [ ] Servable by hash

## Test
Send image, verify in DB, verify synced to second server.
