# Spec 43 — General file transfer codec (0x16/0x96)

## Dependencies
Spec 14 (header), Spec 21-25 (meshpipe + compression).

## Concept
Share small files (configs, notes, GPX tracks, etc) over mesh. Not media — text/data scale. **All file data compressed.**

## Limits
- **Max size**: 50KB (hard cap)
- **Recommended**: <10KB
- **Use cases**: text files, JSON, GPX, small configs

## Wire format
```
FILE_SEND (0x16):
  [0-3] header
  [4]   channel_idx (0 = DM to specific node)
  [5]   file_type (0x01=text, 0x02=json, 0x03=gpx, 0x04=binary)
  [6]   name_len
  [7..] name (utf8)
       size u16
       data (meshpipe if >1 frame)

FILE_ACK (0x96):
  [0-3] header
  [4]   status (0=ok, 1=too large, 2=rejected)
  [5-20] hash (for retrieval)
```

## Deliverables
- `encode_file_send(channel, type, name, data)`
- `decode_file_send()`
- `encode_file_ack(status, hash)`

## Acceptance criteria
- [ ] File <150B sends single frame
- [ ] File >150B uses meshpipe
- [ ] Hash returned for dedup/retrieval
- [ ] >50KB rejected with status=1

## Test
Send 5KB text file, verify received intact.
