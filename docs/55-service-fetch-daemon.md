# Spec 55 — Service fetch daemon (internet-side)

## Dependencies
Spec 52-54 (weather, forecast, news), Spec 13 (persistence).

## Concept
Background daemon fetches from internet APIs when online, stores in local cache. Completely separate from mesh serving — fetch happens independently.

## Architecture
```
Internet → Fetch daemon → Local cache (SQLite)
                              ↓
                         Mesh handler → serves cached data
```

## Fetch schedule
| Service | Interval | Source |
|---------|----------|--------|
| Weather | 30 min | NWS api.weather.gov |
| Forecast | 4 hr | NWS |
| Alerts | 15 min | NWS alerts |
| News | 1 hr | Configurable RSS |

## Storage
```sql
service_cache:
  service, key, data, fetched_at, expires_at

alerts:
  id, type, severity, headline, expires, geojson
```

## Offline behavior
- No internet? Serve stale cache
- Include `fetched_at` in response so client knows age
- Client shows "Last updated X ago"

## Deliverables
- Fetch workers per service
- SQLite cache schema
- Configurable sources (config.toml)
- Graceful offline (serve stale)

## Acceptance criteria
- [ ] Fetches on schedule when online
- [ ] Caches survive restart
- [ ] Stale data served when offline
- [ ] Fetch errors logged, don't crash

## Test
Disconnect internet, verify stale cache served with old timestamp.
