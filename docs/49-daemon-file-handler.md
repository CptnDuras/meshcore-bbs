# Spec 49 — Daemon file handler

## Dependencies
Spec 43 (file codec), Spec 21-23 (meshpipe), Spec 40 (server sync).

## Task
Handle incoming files: receive, store, sync, serve.

## Storage
```sql
files:
  id, hash, channel_idx, sender, ts,
  file_type, name, size, data
```

## Deliverables
- Handle 0x16 (FILE_SEND)
- Reassemble via meshpipe if multi-frame
- Store content-addressed by hash
- Sync to peer servers
- Serve on request (FILE_GET 0x17 → FILE_DATA 0x97)

## Acceptance criteria
- [ ] File received and stored
- [ ] Hash matches content
- [ ] Synced to peer servers
- [ ] Retrievable by hash

## Test
Send file, verify in DB, request by hash, verify returned.
