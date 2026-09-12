# Spec 11 — Feature Catalog (surveyed from multiple BBS systems)

Sourced from mesh-citadel, classic Citadel, ENiGMA½, WWIV, Synchronet, FidoNet.
Filtered for a ~160-byte high-latency mesh text transport. Priority: must/should/nice.

## MUST (core loop + moderation + transport)
- Permission levels enforced (UNVERIFIED/TWIT/USER/AIDE/SYSOP) + action gating.
- New-user verification workflow (sysop/aide verifies before posting).
- Twit handling (twit posts hidden from others), ban/disable, delete message,
  promote/demote.
- Read/unread pointers per room; (N)ew scan; (G)oto next-unread.
- Rooms + navigation: (K)nown rooms w/ unread markers, (C)hange room.
- Private mail + new-mail notice on login; message length caps; paged output.
- Per-room circular buffer (retention cap) to bound DB.
- Terse single-letter command aliases.

## SHOULD (community depth)
- Message threading (reply refs), quoting/reply, in-room search, subject lines.
- Oneliners/graffiti wall, bulletins, last-callers list.
- User bio/profile, user status/availability, user directory.
- TELL/page a user (async), sysop page.
- Message forwarding, move/copy (aide), zap/skip/ungoto room, ignore room.
- User block (user-initiated), rate limiting (mesh self-defense).
- Reverse/range reading (last N / first N).

## NICE (flavor)
- Polls/voting, a single async text mini-game (door), fortunes/QOTD,
  achievements, room subscriptions, passworded rooms, time limits.

## EXCLUDED (transport-incompatible)
- ANSI/ASCII art & color, file transfer/XMODEM, live multi-node chat,
  DOS doors/dropfiles. (FTN/QWK: marginal/heavy — only as a future mesh gateway.)

## Implementation order (this session)
1. Permissions + verification (foundation) — Spec 10.
2. Rooms + read/unread + N/G/K/C navigation.
3. Multi-packet message entry (E, '.' to end).
4. Mail (private) + new-mail notice.
5. Moderation: verify/twit/ban/delete/promote.
6. Community adds as time allows: oneliners, bulletins, last-callers, TELL,
   user profile, forwarding, rate limiting.
All test-first (offline against in-memory sqlite).
