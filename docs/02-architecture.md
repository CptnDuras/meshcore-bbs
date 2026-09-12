# Software Architecture

## Guiding principles

- **Single static binary**, pure V where possible, minimal external deps.
- **Transport-agnostic core.** The protocol/frame layer does not know or care whether
  bytes come from serial, TCP, or BLE. This is the same seam the bridge plugs into.
- **Store-and-forward everywhere.** The daemon owns all state (SQLite); the mesh is
  treated as an unreliable, delayed pipe.
- **Additive services.** Adding a new BBS command or service is one handler, not a
  release.

## Module layout

```
meshbbs/
  v.mod
  docs/                     # these specs
  src/
    main.v                  # entry: config, wire up transport + services, run loop
    transport/
      transport.v           # Transport interface (open/read_frame/write_frame/close)
      serial.v              # SerialTransport: term.termios raw 115200 + '<'/'>' framing
      (later) tcp.v         # TcpTransport: for meshcore-proxy / wifi firmware
      (later) meshtastic.v  # Meshtastic transport (protobuf-over-serial) for the bridge
    protocol/
      codes.v               # command/response/push code constants (from the spec)
      frame.v               # '<'/'>' length-prefixed frame read/write over a Transport
      encode.v              # build CMD_* frames (APP_START, SEND_TXT_MSG, ...)
      decode.v              # parse RESP_*/PUSH_* frames into typed structs
    services/
      registry.v            # command dispatch: text -> handler
      bbs.v                 # HELP / POST / READ / LIST
      (later) wx.v, checkin.v, last.v
    bridge/
      (later) bridge.v      # rules for relaying between two transports
    store/
      store.v               # SQLite: packet log, messages, boards, nodes, checkins
    web/
      (later) admin.v       # HTMX admin dashboard
```

## The Transport interface (the key abstraction)

```
interface Transport {
mut:
    open() !
    // Returns one complete protocol frame's payload (code byte + fields),
    // with transport-specific framing already stripped.
    read_frame() ![]u8
    // Writes one complete frame payload, adding transport-specific framing.
    write_frame(payload []u8) !
    close()
}
```

- `SerialTransport` implements framing with the MeshCore USB rule: outbound `'<'` (0x3C)
  + uint16 LE length + payload; inbound `'>'` (0x3E) + uint16 LE length + payload.
  (Naming per spec: *outbound* = radio→app, *inbound* = app→radio.)
- A BLE transport would map one frame = one characteristic value (no length prefix).
- A TCP transport (meshcore-proxy / wifi firmware) reuses the same `'<'`/`'>'` framing
  over a socket instead of a tty.

The `protocol/` layer only ever sees decoded frame payloads, so encode/decode is written
once and works across all transports.

## Data flow (Phase 0–2)

```
radio --frame--> SerialTransport.read_frame() --payload--> decode.v --typed-> 
    main loop:
      - log to store (always)
      - if PUSH_CODE_MSG_WAITING: pump CMD_SYNC_NEXT_MESSAGE until NO_MORE_MESSAGES
      - each received text message -> services.registry.dispatch(text) -> reply text
    reply -> encode.v (CMD_SEND_TXT_MSG) -> SerialTransport.write_frame() --frame--> radio
```

## Data flow (Phase 3, bridge)

```
TransportA (MeshCore) <-> decode/encode <-> bridge rules <-> decode/encode <-> TransportB (Meshtastic)
                                    |
                              services + store (shared)
```

Bridge concerns to design in Phase 3: message de-duplication, loop prevention,
addressing/namespacing across networks, and which message classes are allowed to cross.

## Concurrency model

- A single reader loop per transport (blocking `read_frame`), feeding a channel of
  decoded events.
- A main event loop consumes events, updates the store, and issues replies.
- Keep it single-threaded-ish and simple for Phase 0; the mesh is slow enough that
  throughput is never the constraint. Revisit only if the bridge needs concurrent
  readers on two transports (it will — one reader thread per transport, shared store).
