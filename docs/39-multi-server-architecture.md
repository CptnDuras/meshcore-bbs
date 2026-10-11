# Spec 39 — Multi-server channel architecture

## Dependencies
Spec 13 (channel msg store), Spec 14 (appproto header).

## Concept
Multiple meshbbs servers on the same channel:
- **Redundancy**: if one node is down, others respond
- **Sync**: servers share state (messages, files, events)
- **Specialization**: different servers offer different services (weather, files, search)

This creates an **off-grid internet** — distributed services over mesh.

## Server roles (examples)
| Role | Function |
|------|----------|
| History | Stores/serves channel history |
| Weather | Fetches/caches WX data |
| Files | Stores/serves shared files |
| Search | Indexes content for search |
| Gateway | Bridges to internet when available |

## Wire additions
- **Server announce (0x02)**: server broadcasts capabilities on join
- **Server list (0x82)**: response listing known servers + roles
- **Request routing**: client can target specific server or any

## Deliverables
- `encode_server_announce(server_id, roles[])`
- `decode_server_announce()`
- Server discovery: servers listen for announces, build roster

## Acceptance criteria
- [ ] Server announces itself on startup
- [ ] Other servers see the announce
- [ ] Client can query server list

## Test
Run 2 servers on same channel, verify mutual discovery.
