# Phased Delivery Plan

Each phase is independently useful and shippable. The BBS is delivered FIRST as a
human-typed text experience over the mesh (universal, retro, works with stock MeshCore
clients). A richer encoded app protocol + React Native client come LATER as a second
presentation over the same operations core — NOT a rewrite.

## Architectural spine (applies across phases)

- **Operations core** (presentation-agnostic): login, list_boards, read, post, reply,
  who, new-message counts, etc. Plus a per-user **session state machine**.
- **Presentation A — human text BBS** (Phases 1-2): maps typed commands -> operations ->
  paginated text replies. Lightweight, universal, retro.
- **Presentation B — encoded app protocol** (Phases 4-5): structured messages, base64/
  base85 encoded, fragmented/reassembled over the 160-byte transport, for rich clients.
- See docs/02-architecture.md for the layer diagram.

## Phase 0 — Talk to one radio (local, on FreeBSD)

Develop on the current FreeBSD box with the Companion (USB Serial) Heltec on /dev/cuaU0
(port is a config flag; later points at /dev/ttyUSB0 on the Pi). Done when the V binary:
1. Opens the port, sets raw 115200, does CMD_APP_START, prints decoded RESP_CODE_SELF_INFO.
2. Logs every framed packet to SQLite (code, ts, raw hex).
3. Echoes a received text message back to the sender (proves receive -> parse -> send).

## Phase 1 — BBS session engine + text presentation (the core)

The classic-BBS heart. Server-side session state keyed by sender node pubkey.

- **Session state machine**: LOGGED_OUT/GUEST -> MAIN_MENU -> MESSAGE_AREA ->
  READING_BOARD -> POSTING -> ... with idle timeout (auto-logoff).
- **Two auth tiers**:
  - GUEST (no login): read public boards, WHO; no posting/private areas.
  - USER (explicit `LOGIN <handle> <password>`): full access; passwords stored HASHED
    (argon2/bcrypt). Identity also bound to sender pubkey for a soft second factor.
  - `[N]ew user` registration flow (pick handle + password).
- **Message boards**: LIST boards, READ board, POST, REPLY; last-read pointers per user.
- **Multi-message menus**: long screens are sent as multiple mesh messages (a burst),
  with a sane BURST CAP; past the cap require `[C]ontinue` to fetch more (retro + good
  mesh citizenship).
- Persisted in SQLite (users, boards, messages, sessions). See docs/06-data-model.md.

## Phase 2 — Retro polish

- ASCII-art login banner / welcome screen.
- Single-key menu commands: [M]essages [F]iles [W]ho [G]oodbye, etc.
- "You have N new messages since your last call."
- WHO / recently-seen nodes; last-caller log.
- Sign-off: "Thanks for calling. NO CARRIER."

## Phase 3 — More services (optional, additive handlers)

- WX (weather), CHECKIN (roll-call), LAST <node> — extra operations behind the same core.

## Phase 4 — Encoded app-protocol transport (Presentation B foundation)

Build the reliable-ish structured transport over MeshCore text messages:
- App message schema (terse field codes; chunky requests, not chatty).
- Encoding: base64 to start (simple, ~33% overhead); consider base85 (~25%) later.
- Fragmentation/reassembly: numbered chunks, out-of-order handling, ACK/NACK,
  retransmit-missing, reassembly buffer, timeouts. (A small reliable transport — respect
  the effort.)
- Rate limiting; be a conservative mesh citizen (more airtime than human text).

## Phase 5 — React Native app

- Phone app speaking the Phase 4 encoded protocol to the daemon. Rich UI locally; mesh
  carries small encoded/fragmented app messages. Same operations core as the text BBS.

## Later / parallel (unchanged from earlier planning)

- MeshCore <-> Meshtastic bridge (second radio; protobuf transport).
- Sensor/telemetry nodes feeding the service layer.
- Local web SYSOP/operator dashboard (Model C) — an operator tool, NOT the user path.
