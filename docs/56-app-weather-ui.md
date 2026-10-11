# Spec 56 — App: Weather/forecast UI

## Dependencies
Spec 52-53 (weather/forecast codecs), Spec 35 (services scaffold), Spec 38 (bundled assets).

## Design language
- Card-based layout in Services tab
- Weather card: icon + temp + conditions
- Forecast: horizontal scroll of day cards
- "Updated X ago" timestamp
- Stale indicator if >2hr old (amber dot)

## Task
Display weather and forecast from service requests.

## Deliverables
- Weather card widget
- Forecast row widget (horizontal scroll)
- Auto-request on tab open (cache 5 min locally)
- Condition code → bundled icon mapping
- Stale data indicator

## Condition codes → icons
| Code | Condition | Icon |
|------|-----------|------|
| 0 | Clear | sun |
| 1 | Partly cloudy | cloud-sun |
| 2 | Cloudy | cloud |
| 3 | Rain | rain |
| 4 | Thunderstorm | storm |
| 5 | Snow | snow |
| 6 | Fog | fog |
| 7 | Wind | wind |

## Acceptance criteria
- [ ] Weather card shows current conditions
- [ ] Forecast shows 3-7 day cards
- [ ] Icons render from bundled assets
- [ ] Stale indicator shows if data old
- [ ] Pulls fresh on tab open if cache expired

## Test
Open Services tab, verify weather loads, verify icons match conditions.
