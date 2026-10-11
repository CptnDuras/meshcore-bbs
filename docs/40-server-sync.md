# Spec 40 — Server-to-server state sync

## Dependencies
Spec 39 (multi-server architecture), Spec 21-25 (meshpipe + compression).

## Concept
Servers sync state so any can answer. No single point of failure. **All sync payloads compressed.**

## Sync model
- **Eventual consistency**: servers gossip state changes
- **Vector clocks**: detect conflicts, last-write-wins or merge
- **Selective sync**: only sync relevant data per role

## What syncs
| Data | Sync? | Strategy |
|------|-------|----------|
| Channel messages | Yes | Append-only, dedupe by hash |
| User accounts | Yes | Last-write-wins |
| Files | Yes | Content-addressed (hash) |
| Weather cache | No | Each fetches independently |

## Wire additions
- **Sync request (0x03)**: "give me updates since X"
- **Sync response (0x83)**: batch of records
- **Sync push (0x04)**: "here's a new record"

## Deliverables
- `encode_sync_req(since_ts)`
- `encode_sync_push(record)`
- Sync loop in daemon: periodic push/pull

## Acceptance criteria
- [ ] Server A posts msg, Server B receives via sync
- [ ] New server catches up from existing server
- [ ] Duplicate messages deduplicated

## Test
Post on Server A, verify appears on Server B within 30s.
