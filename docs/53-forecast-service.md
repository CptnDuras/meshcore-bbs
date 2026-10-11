# Spec 53 — Forecast service (0x21/0xA1)

## Dependencies
Spec 52 (weather service), Spec 25 (compression).

## Concept
Multi-day forecast. Node fetches, compresses aggressively, serves over mesh.

## Wire format
```
FORECAST_REQ (0x21):
  [0-3] header
  [4-5] lat (i16, *100)
  [6-7] lon (i16, *100)
  [8]   days (1-7, default 3)

FORECAST_RES (0xA1):
  [0-3] header
  [4-7] timestamp (u32)
  [8]   num_days
  [9..] days[] (compressed):
    [0-3] date (u32 unix day)
    [4]   condition_code
    [5-6] high_c (i16, *10)
    [7-8] low_c (i16, *10)
    [9]   precip_pct
```

~10 bytes/day × 7 = 70 bytes + header. Compresses to ~40-50 bytes.

## Deliverables
- `encode_forecast_req()`, `decode_forecast_req()`
- `encode_forecast_res()`, `decode_forecast_res()`
- Daemon: fetch + cache (2-4hr) + serve

## Acceptance criteria
- [ ] 3-day forecast in single frame (<150B)
- [ ] 7-day forecast compresses to <80 bytes
- [ ] App renders day cards with icons

## Test
Request 5-day forecast, verify renders correctly.
