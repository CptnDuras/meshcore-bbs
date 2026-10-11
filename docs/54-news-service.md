# Spec 54 — News/alerts service (0x22/0xA2)

## Dependencies
Spec 14 (header), Spec 25 (compression), Spec 42 (service discovery).

## Concept
Node fetches headlines/alerts (NWS alerts, RSS feeds), caches, serves compressed summaries. Not full articles — headlines only.

## Wire format
```
NEWS_REQ (0x22):
  [0-3] header
  [4]   category (0=all, 1=weather_alerts, 2=news, 3=emergency)
  [5]   count (1-10, default 5)

NEWS_RES (0xA2):
  [0-3] header
  [4-7] timestamp (u32)
  [8]   num_items
  [9..] items[] (compressed):
    [0]   category
    [1]   priority (0=normal, 1=urgent, 2=emergency)
    [2]   title_len
    [3..] title (utf8, max 80 chars)
    [..]  age_mins (u16, how old)
```

## Headlines only
- No full article content
- Max 80 chars per headline
- Saves airtime

## Deliverables
- `encode_news_req()`, `decode_news_req()`
- `encode_news_res()`, `decode_news_res()`
- Daemon: RSS/NWS fetch + cache + serve
- Priority sorting (emergency first)

## Acceptance criteria
- [ ] 5 headlines fit in single frame
- [ ] Emergency alerts have priority=2
- [ ] NWS alerts auto-fetched for region
- [ ] Headlines truncated to 80 chars

## Test
Request news, verify headlines render, verify alerts prioritized.
