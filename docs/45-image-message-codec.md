# Spec 45 — Image message codec (0x14/0x94)

## Dependencies
Spec 14 (header), Spec 44 (image compression).

## Wire format
```
IMAGE_MSG (0x14):
  [0-3] header
  [4]   channel_idx
  [5]   img_type (0x01=jpeg, 0x02=webp, 0x03=png)
  [6-7] width u16
  [8-9] height u16
  [10-11] size u16 (total bytes)
  [12..] image data (first segment, rest via meshpipe)

IMAGE_ACK (0x94):
  [0-3] header
  [4]   status (0=ok, 1=too large, 2=invalid)
```

## Behavior
- Small images (<150B): single frame
- Larger: meshpipe multi-frame transfer
- Server stores, syncs to other servers
- Clients fetch on demand or inline

## Deliverables
- `encode_image_msg(channel_idx, image_bytes)`
- `decode_image_msg()`
- `encode_image_ack(status)`

## Acceptance criteria
- [ ] Small image sends in single frame
- [ ] Large image uses meshpipe
- [ ] Received image displays correctly

## Test
Send 2KB image, verify received and displayed.
