# Transport & Security Decision

## Decision

**Use USB serial for the gateway control link in v1.** Wrap it behind a `Transport`
interface so the protocol code is transport-agnostic and BLE/TCP remain future options
without committing to them now.

## Transports MeshCore companion firmware supports

These are separate firmware builds — a radio does one at a time, so transport choice is
partly a flashing decision.

| Transport   | Firmware build          | Framing                              |
|-------------|-------------------------|--------------------------------------|
| USB serial  | companion_radio_usb     | '<'/'>' + uint16 LE length + payload |
| BLE         | companion_radio_ble     | one frame = one BLE characteristic   |
| TCP / Wi-Fi | companion_radio_wifi    | '<'/'>' framing over a TCP socket    |

## Why serial (security + fit)

- **No network attack surface on the control link.** BLE advertises/pairs; Wi-Fi/TCP
  opens a listening port. Both are remotely reachable. A USB cable is physically scoped —
  an attacker must be plugged into the Pi. Right choice for an always-on unattended box.
- **BLE pairing is the weak point.** Security rests on a PIN (`ble_pin` in
  RESP_CODE_DEVICE_INFO); the radio has no screen/keyboard for strong pairing UX.
- **The companion protocol has no transport auth of its own.** Over TCP it is plaintext
  framing — anyone who can reach the port can drive the radio unless we add auth/TLS.
- **Single-owner.** A serial device is opened by one process — a feature for a dedicated
  daemon.

## Important nuance (don't overclaim)

None of these transports protect the *mesh payload* — MeshCore's end-to-end message
crypto happens on the radio regardless of host transport. Transport choice only affects
the **link between the host and its own radio**. "Serial is more secure" is correct about
that control link specifically — which is exactly the part physically sitting in the
gateway box.

## Serial downsides (chosen with eyes open)

- Physical tethering (fine — the Pi gateway is fixed).
- One host per radio (a feature here).
- USB-serial papercuts: device-path re-enumeration (use /dev/serial/by-id) and ESP32
  auto-reset-on-DTR (don't toggle DTR on open). Neither is a security issue.

## If network access is ever needed

Do NOT flash the radio to Wi-Fi firmware and expose its plaintext TCP. Instead keep the
hardened serial link to the radio and put a proxy in front that WE control and can
authenticate (pattern proven by rgregg/meshcore-proxy: serial radio -> exposed over TCP).
This becomes a `TcpTransport` client to our own proxy, not a change to the radio.

## Consequence for the code

```
Transport (interface)
  |-- SerialTransport   (term.termios raw 115200 + '<'/'>' framing)   <- v1
  |-- (later) TcpTransport   (meshcore-proxy / wifi firmware)
  |-- (later) BleTransport   (only if a use case demands it)
  |-- (later) MeshtasticTransport (Phase 3 bridge; protobuf-over-serial)
```

Serial config uses V's stdlib `term.termios` (no C library to port; libc termios is
called via that module).
