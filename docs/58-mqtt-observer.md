# MQTT observer (optional)

Reports every packet the radio hears to MQTT brokers so the node shows up on mesh maps
(MeshMapper, Waev, LetsMesh) and/or a local broker. **Off by default**; configured entirely
from the web UI (`/mqtt`).

## How it fits together

```
radio ──0x88 LOG_RX_DATA──▶ daemon (bbs/) ──stdin JSON lines──▶ mqtt/publisher.py ──▶ brokers
                              ▲  │                                  │
          web UI /mqtt ──DB──┘  └◀────── status JSON lines ◀────────┘
```

- **Web UI** (`webui/mqtt_ui.v`) edits `mqtt_settings` / `mqtt_brokers` in the shared DB and
  bumps a `rev` counter. It never talks to the radio or the publisher.
- **Daemon** (`bbs/mqtt_runtime.v`) runs `MqttRuntime.tick()` once a second: starts the
  publisher only when MQTT is enabled, an IATA code and ≥1 broker are set, and the radio's
  identity is known; re-sends the config when `rev` changes; stops it (offline status) when
  disabled; restarts it with a 30 s backoff if it dies. Heard packets are forwarded through a
  bounded, non-blocking queue — if the publisher stalls, packets are dropped and counted, the
  radio loop never waits on MQTT.
- **Publisher** (`mqtt/publisher.py`, paho-mqtt) holds the broker connections (tcp / tls / ws /
  wss), publishes retained online/offline status with a last-will, and reports per-broker state
  back on stdout; the daemon writes it to `mqtt_status` for the UI.
- **V TLS is broken on titan**, which is why the network client is Python, not V.

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
# once, in the project venv (FreeBSD compiles ed25519-orlp; needs cc)
venv/bin/pip install -r mqtt/requirements.txt
# rebuild the daemon (needs the meshcore-v branch with 0x88 + key export), then restart it
./build.sh
```

Then open the web UI → **MQTT**: set the IATA code (nearest airport, e.g. `BYG`), add brokers
from presets (`meshmapper`, `waev-a`, `waev-b`, `letsmesh-us`, `letsmesh-eu`, `local`) or a custom
one, and tick **Enable**. Logs: `meshbbs-mqtt.log` (publisher stderr).

Joining a **new region** on MeshMapper is a separate, manual step on their side (≥1, ideally
2–3 observers; the IATA code becomes `<code>.meshmapper.net`).

## Tests

- V: `v test bbs mqttcfg webui` (store, packet parsing/hash against independently computed
  values, runtime lifecycle with a fake pipe, web UI data layer, ORM↔web-UI schema contract)
- Python: `cd mqtt && python -m pytest tests` (auth tokens, publisher with fake paho clients)
- The real-process path (ProcessPipe + publisher + broker) was verified end-to-end on titan
  with an `amqtt` broker; it is not part of the automated suite.

## Layout

| Path | Role |
|---|---|
| `mqttcfg/` | validation, presets, form parsing shared by daemon and web UI |
| `bbs/mqtt.v` | config loading, packet parsing/hash, payload builders |
| `bbs/mqtt_runtime.v` | publisher lifecycle, process pipe, key loading, status intake |
| `webui/mqtt_ui.v`, `templates/mqtt.html` | settings page (all values HTML-escaped) |
| `mqtt/` | `publisher.py`, `auth.py`, `requirements.txt`, tests |
