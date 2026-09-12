# Protocol Reference (MeshCore Companion Radio Protocol)

Authoritative source: MeshCore wiki "Companion Radio Protocol"
(now mirrored at https://docs.meshcore.io/companion_protocol/).
Reference implementations to consult when the spec is ambiguous:
- meshcore-dev/meshcore.js  (official, JS, USB-serial path — most readable)
- meshcore-dev/meshcore_py  (official, Python)
- andrewdavidmackenzie/meshcore-rs (Rust)

NOTE: We do NOT bind or port a C library. There is no canonical C host library — the
MeshCore C++ code is the on-radio firmware/routing core, not a host client. The host side
is ~50-80 lines in every language. We translate the *logic* of the JS/Python references
into idiomatic V, using the frame spec below as the source of truth.

## USB framing

All uint16/uint32 values are LITTLE-ENDIAN.

- **Outbound** (radio -> app): byte `0x3E` (`'>'`), then uint16 length, then payload.
- **Inbound** (app -> radio): byte `0x3C` (`'<'`), then uint16 length, then payload.

The payload's first byte is the command/response/push code.

(BLE variant: one frame = one characteristic value, no length prefix — BLE link layer
handles integrity. TCP/wifi variant: same '<'/'>' framing over a socket.)

## Handshake (Phase 0)

1. Open serial `/dev/ttyUSB0` (or `ttyACM0`) at 115200, raw mode.
2. Send `CMD_APP_START` (1): `[0x01, app_ver:u8, reserved:6 bytes, app_name:varchar]`.
   -> radio replies `RESP_CODE_SELF_INFO` (5): type, tx power, 32-byte pubkey, adv
      lat/lon, radio freq/bw/sf/cr, name.
3. Send `CMD_DEVICE_QUERY` (22): `[0x16, app_target_ver:u8]`.
   -> radio replies `RESP_CODE_DEVICE_INFO` (13): firmware ver, model, build date,
      semantic version, (v3+) max contacts/channels, ble_pin.

## Receiving messages (Phase 0 loop)

- Radio pushes `PUSH_CODE_MSG_WAITING` (0x83) when a text message has arrived.
- App responds by sending `CMD_SYNC_NEXT_MESSAGE` (10) repeatedly:
  - `RESP_CODE_CONTACT_MSG_RECV` (7) or `..._V3` (16): a direct message.
    Fields (v1): pubkey_prefix(6), path_len(1), txt_type(1), sender_timestamp(u32),
    text(remainder). V3 prepends: snr(1), reserved(2).
  - `RESP_CODE_CHANNEL_MSG_RECV` (8) or `..._V3` (17): a channel/broadcast message.
  - `RESP_CODE_NO_MORE_MESSAGES` (10): queue drained; stop pumping.

## Sending messages (Phase 0 loop)

- `CMD_SEND_TXT_MSG` (2): `[0x02, txt_type:u8=0, attempt:u8, sender_timestamp:u32,
  pubkey_prefix:6 bytes (first 6 of recipient pubkey), text:varchar (<=160 bytes)]`.
  -> `RESP_CODE_SENT` (6): send type (flood/direct), 4-byte expected-ACK/tag,
     suggested_timeout(u32).
- `PUSH_CODE_SEND_CONFIRMED` (0x82): later, when the matching ACK arrives — carries the
  4-byte ack code + round-trip ms.
- Channel/broadcast send: `CMD_SEND_CHANNEL_TXT_MSG` (3).

## Codes we care about (Phase 0-2)

Commands (app -> radio):
- CMD_APP_START = 1
- CMD_SEND_TXT_MSG = 2
- CMD_SEND_CHANNEL_TXT_MSG = 3
- CMD_GET_CONTACTS = 4
- CMD_SYNC_NEXT_MESSAGE = 10
- CMD_DEVICE_QUERY = 22

Responses (radio -> app):
- RESP_CODE_OK = 0
- RESP_CODE_ERR = 1               (followed by err_code byte)
- RESP_CODE_CONTACTS_START = 2
- RESP_CODE_CONTACT = 3
- RESP_CODE_END_OF_CONTACTS = 4
- RESP_CODE_SELF_INFO = 5
- RESP_CODE_SENT = 6
- RESP_CODE_CONTACT_MSG_RECV = 7
- RESP_CODE_CHANNEL_MSG_RECV = 8
- RESP_CODE_CURR_TIME = 9
- RESP_CODE_NO_MORE_MESSAGES = 10
- RESP_CODE_DEVICE_INFO = 13
- RESP_CODE_CONTACT_MSG_RECV_V3 = 16
- RESP_CODE_CHANNEL_MSG_RECV_V3 = 17

Push notifications (radio -> app, unsolicited):
- PUSH_CODE_ADVERT = 0x80
- PUSH_CODE_PATH_UPDATED = 0x81
- PUSH_CODE_SEND_CONFIRMED = 0x82
- PUSH_CODE_MSG_WAITING = 0x83

Constants:
- txt_type: PLAIN=0, CLI_DATA=1, SIGNED_PLAIN=2
- adv_type: NONE=0, CHAT=1, REPEATER=2, ROOM=3
- err_code: UNSUPPORTED_CMD=1, NOT_FOUND=2, TABLE_FULL=3, BAD_STATE=4,
  FILE_IO_ERROR=5, ILLEGAL_ARG=6

## Implementation risks / notes

- ESP32 radios auto-reset on serial DTR toggle — avoid toggling DTR on open, or the
  radio reboots each connect. (term.termios: do not assert DTR/RTS on open.)
- USB device path can change (ttyUSB0 <-> ttyUSB1) on re-enumeration — prefer a stable
  `/dev/serial/by-id/...` path via udev.
- Message text max 160 bytes; long BBS output must be paginated across multiple sends.
- Meshtastic (Phase 3) is a DIFFERENT protocol: protobuf-over-serial with its own
  framing. Plan to hand-decode only the packet types the bridge needs.
