# Spec 52 — Weather service (0x20/0xA0)

## Dependencies
Spec 14 (header), Spec 25 (compression), Spec 42 (service discovery).

## Concept
Node with internet fetches weather, caches locally, serves over mesh. Clients request via binary protocol — no text commands.

## Behavior
- Node fetches from NWS/API periodically (when online)
- Caches for 30-60 min
- Serves cached data to mesh requests
- Works offline (serves stale cache with timestamp)

## Wire format
```
WX_REQ (0x20):
  [0-3] header
  [4-5] lat (i16, *100)
  [6-7] lon (i16, *100)
  (or 0,0 for node's default location)

WX_RES (0xA0):
  [0-3] header
  [4-7] timestamp (u32)
  [8]   condition_code (bundled icon maps to this)
  [9-10] temp_c (i16, *10)
  [11-12] humidity (u8)
  [13]  wind_kph (u8)
  [14]  wind_dir (u8, 0-15 = N,NNE,NE...)
  [15..] description (compressed utf8)
```

## Deliverables
- `encode_wx_req()`, `decode_wx_req()`
- `encode_wx_res()`, `decode_wx_res()`
- Daemon: fetch + cache + serve handler
- Condition codes map to bundled app icons

## Acceptance criteria
- [ ] Request returns cached weather
- [ ] Response <50 bytes typical (compressed)
- [ ] Stale cache served with old timestamp
- [ ] App renders icon from condition_code

## Test
Request weather, verify response, verify icon renders.
