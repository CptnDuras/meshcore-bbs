# MQTT observer (optional)

Reports every packet the radio hears to MQTT brokers so the node shows up on mesh maps
(MeshMapper, Waev, LetsMesh) and/or a local broker. **Off by default**; configured entirely
from the web UI (`/mqtt`).

## How it fits together

```
radio ──0x88 LOG_RX_DATA──▶ daemon (bbs/) ── JSON command lines ──▶ publisher ──▶ brokers
                              ▲  │            (in-process threads)        │
          web UI /mqtt ──DB──┘  └◀────────── JSON status lines ◀─────────┘
```

- **Web UI** (`webui/mqtt_ui.v`) edits `mqtt_settings` / `mqtt_brokers` in the shared DB and
  bumps a `rev` counter. It never talks to the radio or the publisher.
- **Daemon** (`bbs/mqtt_runtime.v`) runs `MqttRuntime.tick()` once a second: starts the
  publisher only when MQTT is enabled, an IATA code and ≥1 broker are set, and the radio's
  identity is known; re-sends the config when `rev` changes; stops it (offline status) when
  disabled; restarts it with a 30 s backoff if it dies. Heard packets are forwarded through a
  bounded, non-blocking queue — if the publisher stalls, packets are dropped and counted, the
  radio loop never waits on MQTT.
- **Publisher** (`bbs/mqtt_publisher.v`) runs **inside the daemon binary** on its own threads
  and speaks to the daemon through the `MqttPipe` interface (JSON command lines in, JSON status
  lines out). One worker thread per broker dials, sends CONNECT with a retained `offline`
  last-will, publishes retained `online`, sends QoS 0 packets, keeps the link alive (PINGREQ,
  60 s keepalive), reconnects with 1 s → 120 s backoff, and renews token credentials before
  they expire. Per-broker state is reported back and the daemon writes it to `mqtt_status`.
- **No external runtime**: the MQTT 3.1.1 codec (`mqtt_packet.v`), the RFC 6455 WebSocket
  client (`mqtt_ws.v`), TCP/TLS/WS/WSS transports (`mqtt_transport.v`) and Ed25519 signing
  (`mqtt_token.v`) are all V. The result is a single self-contained binary — no Python, no
  venv, no `paho-mqtt`.

## Transport security

- `tls` and `wss` **always verify** the broker's certificate chain and host name; there is no
  "skip verification" option. (V's TLS only validates when asked to, so the transport
  explicitly passes `validate: true` and a CA bundle.)
- The CA bundle is the first of: `$MESHBBS_CA_FILE` (replaces the system bundle, handy for a
  private CA), `<MESHBBS_HOME>/cacert.pem` (ship one next to the binary for hosts without a
  system bundle), then the usual system locations (`/etc/ssl/certs/ca-certificates.crt`,
  `/etc/pki/tls/certs/ca-bundle.crt`, `/usr/local/share/certs/ca-root-nss.crt`,
  `/etc/ssl/cert.pem`, …). If none exists the broker shows an error and nothing is sent.
- A broker addressed by IP will fail the host-name check unless the certificate lists that IP.

## Topics and payloads

Same shape the repeater bridges publish, so existing consumers accept it:

- `meshcore/<IATA>/<PUBKEY>/status` — retained `online` / `offline` (last-will)
- `meshcore/<IATA>/<PUBKEY>/packets` — one flat-string JSON object per packet:
  `origin, origin_id, timestamp, type, direction, time, date, len, packet_type, route,
  payload_len, raw, SNR, RSSI, hash`
- Packet `hash` = first 8 bytes of SHA-256(payload type [+ path_len for TRACE] + payload),
  upper-case hex, as in `Packet::calculatePacketHash`. Unparseable packets are not published.

## Authentication

- `none`, `password`, or `token`. Token = Ed25519 JWT signed with the node's own key; login is
  `v1_<PUBKEY>` + token, claims `publicKey, iat, exp, aud, client`, refreshed before expiry.
- The key comes from the radio (`CMD_EXPORT_PRIVATE_KEY`) and requires firmware built with
  `ENABLE_PRIVATE_KEY_EXPORT=1`. It is read lazily, held **in memory only**, passed to the
  publisher over its stdin, and never written to the DB, logs, or UI. If the firmware refuses,
  the UI shows the reason and token brokers report an error while other brokers keep working
  (retry every 5 min).
- Broker passwords for `password` auth are stored in the DB in plain text (the UI is
  tailnet-only and never renders them back).

## Setup

```sh
./build.sh          # builds the daemon; the MQTT observer is part of it
```

Then open the web UI → **MQTT**: set the IATA code (nearest airport, e.g. `BYG`), add brokers
from presets (`meshmapper`, `waev-a`, `waev-b`, `letsmesh-us`, `letsmesh-eu`, `local`) or a custom
one, and tick **Enable**. Status per broker (connecting / connected / error with the reason) is
shown on the same page.

Joining a **new region** on MeshMapper is a separate, manual step on their side (≥1, ideally
2–3 observers; the IATA code becomes `<code>.meshmapper.net`).

## Tests

- `v test bbs mqttcfg webui` covers: store and packet parsing/hash against independently
  computed values, runtime lifecycle with a fake pipe, the MQTT/WebSocket wire codecs, Ed25519
  signatures and tokens pinned byte-for-byte to the reference implementation (`ed25519_orlp`),
  the publisher (real worker threads against an in-memory fake broker: login/will, status,
  packet routing, reconfiguration, token refresh, reconnect, stop), and the web UI data layer.
- `bbs/mqtt_integration_test.v` drives the real transports against a real broker and is skipped
  unless pointed at one:

  ```sh
  MQTT_IT_TCP=127.0.0.1:1883 MQTT_IT_WS=127.0.0.1:9001/ \
  MQTT_IT_TLS=localhost:8883 MQTT_IT_WSS=localhost:9002/ \
  MESHBBS_CA_FILE=ca.pem v test bbs/mqtt_integration_test.v
  ```

  (A throwaway Mosquitto with those four listeners and a private CA is enough.)

## Layout

| Path | Role |
|---|---|
| `mqttcfg/` | validation, presets, form parsing shared by daemon and web UI |
| `bbs/mqtt.v` | config loading, packet parsing/hash, payload builders |
| `bbs/mqtt_runtime.v` | publisher lifecycle, key loading, status intake |
| `bbs/mqtt_publisher.v` | in-process publisher: per-broker workers, manager, `MqttPipe` |
| `bbs/mqtt_packet.v`, `mqtt_ws.v`, `mqtt_transport.v` | MQTT 3.1.1 codec, WebSocket client, TCP/TLS/WS/WSS transports |
| `bbs/mqtt_token.v` | Ed25519 (expanded-key) signing and login tokens |
| `webui/mqtt_ui.v`, `templates/mqtt.html` | settings page (all values HTML-escaped) |
