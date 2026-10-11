# Spec 57 — App: News/alerts UI

## Dependencies
Spec 54 (news codec), Spec 35 (services scaffold), Spec 38 (bundled assets).

## Design language
- List in Services tab below weather
- Alert card: priority badge + headline + age
- Emergency: red background, pinned to top
- Urgent: amber badge
- Normal: no badge
- Tap: no action (headlines only, no full article)

## Task
Display news headlines and alerts from service requests.

## Deliverables
- News list widget
- Alert card (priority-styled)
- Auto-request on tab open
- Sort: emergency → urgent → normal → by age
- "X min ago" timestamp

## Priority styling
| Priority | Style |
|----------|-------|
| 2 (emergency) | Red bg (#DC2626), white text, pinned top |
| 1 (urgent) | Amber badge (#F59E0B) |
| 0 (normal) | No badge, grey timestamp |

## Acceptance criteria
- [ ] Headlines render in list
- [ ] Emergency alerts pinned to top
- [ ] Priority badges correct
- [ ] Age shows "X min/hr ago"
- [ ] Pulls fresh on tab open if cache expired

## Test
Receive emergency alert, verify red card pinned to top.
