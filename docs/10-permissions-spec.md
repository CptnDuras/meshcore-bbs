# Spec 10 — Permissions & User Verification

Foundation for rooms, mail, and sysop tools. Adopted from mesh-citadel's
`auth/permissions.py` model.

## Permission levels (ordered)

```
UNVERIFIED = 0   // just registered; can read public rooms, cannot post
TWIT       = 1   // shadow-restricted troublemaker (posts hidden from others)
USER       = 2   // normal verified user; read/post/mail
AIDE       = 3   // moderator; verify users, create/delete rooms
SYSOP      = 4   // full control
```

Stored as an int on the User model (`perm int`).

## Rules

- **First registered user becomes SYSOP** automatically (bootstrap). All others
  start **UNVERIFIED**.
- **UNVERIFIED** users may: read public rooms, HELP, WHO(limited), LOGOUT. They
  may NOT post or enter mail until verified.
- **Verification**: an AIDE or SYSOP runs `VERIFY <handle>` which raises the
  target from UNVERIFIED to USER. `TWIT <handle>` lowers to TWIT; `UNTWIT` /
  `PROMOTE`/`DEMOTE` adjust as needed (AIDE+ only, cannot exceed own level).
- **Action gating** via an action→required-level map (`min_level(action)`); the
  dispatcher checks `has_permission(user, action)` before executing.

## Action requirements (initial map)

| Action        | Min level  |
|---------------|------------|
| read          | UNVERIFIED |
| who           | UNVERIFIED |
| post          | USER       |
| mail          | USER       |
| enter         | USER       |
| create_room   | AIDE       |
| delete_room   | AIDE       |
| verify_user   | AIDE       |
| set_perm      | AIDE       |
| sysop_config  | SYSOP      |

## Data model change

Add to `User`: `perm int` (default 0 = UNVERIFIED). Migration: existing users
default to UNVERIFIED except the bootstrap sysop.

## API (engine/permissions.v)

- `enum Perm { unverified twit user aide sysop }`
- `fn min_level(action string) Perm`
- `fn has_permission(u User, action string) bool`
- `fn (mut e Engine) verify_user(actor User, target_handle string) string`
- `fn (mut e Engine) set_perm(actor User, target_handle string, level Perm) string`

## Behavior details

- A TWIT can log in and appears to function, but their posts are flagged
  `hidden` and not shown to other users (deferred to rooms/message spec, but the
  perm level is defined here).
- An actor may not set a permission >= their own level (an AIDE cannot create a
  SYSOP).

## Test cases (v test — offline, in-memory sqlite)

1. **bootstrap_sysop**: first `create_user` yields perm == SYSOP; second yields
   UNVERIFIED.
2. **unverified_cannot_post**: UNVERIFIED user POST -> denied message; USER can.
3. **min_level_map**: `min_level('post') == .user`, `min_level('read') ==
   .unverified`, `min_level('create_room') == .aide`.
4. **has_permission**: USER has read+post+mail, not create_room; AIDE has
   create_room; SYSOP has sysop_config.
5. **verify_user_raises**: AIDE verifies UNVERIFIED -> becomes USER.
6. **verify_requires_aide**: USER attempting VERIFY -> denied.
7. **cannot_exceed_own_level**: AIDE set_perm(target, SYSOP) -> denied; AIDE
   set_perm(target, USER) -> ok.
8. **twit_lowers**: AIDE TWIT <user> -> target perm == TWIT.
