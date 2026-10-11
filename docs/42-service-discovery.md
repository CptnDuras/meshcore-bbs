# Spec 42 — Service registry and discovery

## Dependencies
Spec 39 (multi-server).

## Concept
App discovers available services dynamically. "What can this mesh do?"

## Service types
| Code | Service | Description |
|------|---------|-------------|
| 0x01 | history | Channel message history |
| 0x02 | weather | Weather data (local cache) |
| 0x03 | files | File storage/sharing |
| 0x04 | search | Content search |
| 0x05 | calendar | Shared calendar |
| 0x06 | bot | Custom bot/automation |
| 0x07 | alerts | Emergency alerts |

Note: No internet gateway. All services run locally on nodes. Weather/news are cached by nodes with internet access, then shared over mesh — not fetched on demand.

## Wire
- **Discover (0x06)**: "what services exist?"
- **Discover response (0x86)**: list of (server_id, service_code, name)

## Deliverables
- `encode_discover()`
- `decode_discover_response()`
- App: query on connect, show available services in Services tab

## Acceptance criteria
- [ ] App sends discover on connect
- [ ] Services tab shows only available services
- [ ] Unavailable services greyed or hidden

## Test
Run server with weather only, verify app shows weather but not files.
