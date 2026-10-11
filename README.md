# meshbbs

A single V daemon (Linux) that connects to mesh radios over serial and provides off-grid
store-and-forward services (a BBS + light commands) and, later, a MeshCore <-> Meshtastic
bridge. Runs on a Raspberry Pi Zero W with two Heltec V3 radios.

Status: **specs only — not yet built.**

## Specs

- [docs/00-overview.md](docs/00-overview.md) — what it is, goals, constraints, non-goals
- [docs/01-phasing.md](docs/01-phasing.md) — phased delivery plan (Phase 0 = spike)
- [docs/02-architecture.md](docs/02-architecture.md) — module layout, Transport interface
- [docs/03-protocol.md](docs/03-protocol.md) — MeshCore companion protocol reference
- [docs/04-transport-and-security.md](docs/04-transport-and-security.md) — why serial
- [docs/05-hardware-notes.md](docs/05-hardware-notes.md) — 915 MHz antenna separation, radios
- [docs/06-data-model.md](docs/06-data-model.md) — SQLite schema by phase
- [docs/58-mqtt-observer.md](docs/58-mqtt-observer.md) — optional MQTT observer (map reporting)

Build note: the daemon depends on the separate `meshcore-v` module (`git@github.com:CptnDuras/meshcore-v.git`),
symlinked into `~/.vmodules/meshcore`. The MQTT observer needs its `mqtt-observer` branch.

## Toolchain

- V 0.5.2 (confirmed installed)
- Serial via V stdlib `term.termios` (no C library to port)
- SQLite for all persistence

## Next step when ready to build

Phase 0 spike: open the serial port, do the `CMD_APP_START` handshake, decode and print
`RESP_CODE_SELF_INFO` from a real MeshCore Heltec V3. See docs/01-phasing.md.
