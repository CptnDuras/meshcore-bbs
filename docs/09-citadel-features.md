# Feature Specs — Citadel-style BBS features (derived from mesh-citadel)

Source of inspiration: **taedryn/mesh-citadel** — a mature MeshCore Citadel BBS
(Python, Raspberry Pi Zero target, py-meshcore). We adopt its proven feature
model, adapted to our stack (V + the `meshcore` V library + ORM Store, SQLite
now / Postgres later). This doc is the **vetted plan**; per-feature specs follow
in `10-*.md` .. `14-*.md`. Implementation is test-first.

## What we already have (baseline, verified live)
- meshcore V library; per-node session state machine (guest/user), persisted.
- bcrypt auth (NEW/LOGIN/LOGOUT), boards (LIST/READ/POST), HELP/MENU/WHO.
- Pagination (burst cap + [C]ontinue helper), pluggable Store, WX command.

## Concepts from mesh-citadel — VET & DECISION

| Citadel concept | Adopt? | Notes / adaptation |
|---|---|---|
| **Rooms** (== our "boards") | Adopt (rename) | Citadel calls them rooms; we'll align terminology to rooms for authenticity. Keep boards table, add room semantics. |
| **System rooms**: Lobby, Mail, Aides, Sysop | Adopt subset | Lobby (default), Mail (private msgs). Aides/Sysop rooms deferred. |
| **Per-user unread pointers** + `(N)ew`, `(G)oto` | Adopt | We have a LastRead model already; wire it to N/G navigation. Core Citadel UX. |
| **`(K)nown rooms`** w/ unread markers (`*`/`-`) | Adopt | Cheap, high-flavor. |
| **`(C)hange room`** | Adopt | Exact-match, case-insensitive. |
| **Permission levels** UNVERIFIED/TWIT/USER/AIDE/SYSOP | Adopt | IntEnum + action→required-level map. First user becomes SYSOP. |
| **Sysop verification of new users** | Adopt | New users land UNVERIFIED; can't post until verified. Sysop `VERIFY <user>`. |
| **Mail** (private user↔user messages) | Adopt | `C mail` then enter recipient; message stored addressed to a user. |
| **Multi-packet message entry** (`.` to end) | Adopt | This is a "workflow": multi-turn state on the session. Key Citadel feel. |
| **`(E)nter message`** | Adopt | Replaces our one-shot POST for the retro flow; keep POST as a shortcut. |
| **User blocking** (block/unblock/is_blocked) | Adopt (later) | Mail-focused; spec now, implement after Mail. |
| **`(W)ho's online`** w/ privacy | Adapt | We lack presence tracking; do a simple recent-poster list first. |
| **`.C` create room** | Adopt | Permission-gated (AIDE+). |
| **In-memory DB w/ periodic flush** | Defer | Optimization; our SQLite file is fine on the Pi to start. |
| **Circular per-room message buffer** (cap N) | Adopt (later) | Bounds DB size on constrained hardware; add as a maintenance job. |
| **TWIT handling** (shadow-muted users) | Adopt (later) | Depends on permission system; spec now. |
| **NOT internet-connected (design purity)** | DEVIATE | mesh-citadel is intentionally offline-only. We already added WX (internet) and want the bridge/ecosystem. We keep internet features OPTIONAL/config-gated so a purist can disable them. |

## Deviations from mesh-citadel (deliberate)
1. **Internet features stay** (WX etc.), but behind config so the BBS can run
   pure-mesh if desired. mesh-citadel forbids them by design; we're a platform.
2. **Terminology**: we adopt "rooms" for authenticity but keep board tables.
3. **Store is pluggable** (SQLite/Postgres); mesh-citadel is SQLite-specific.

## Implementation order (each test-first, each shippable)
1. **Spec 10 — Permissions & verification** (foundation for everything else).
2. **Spec 11 — Rooms & navigation** (rename boards→rooms, N/G/K/C, unread pointers).
3. **Spec 12 — Message entry workflow** (multi-packet E, `.` to end).
4. **Spec 13 — Mail** (private messages via Mail room, addressing).
5. **Spec 14 — Sysop/Aide tools** (VERIFY, .C create room, block/twit) + WHO privacy.

## Testing strategy (applies to all)
- Pure-logic units (engine/permissions/rooms/workflow) are tested **offline**
  against an in-memory SQLite Store via `v test` — no radio needed.
- Each spec lists explicit test cases (happy path + auth-denied + edge cases).
- Live mesh verification (from a second node) is a final manual check per feature,
  not a substitute for automated tests.
