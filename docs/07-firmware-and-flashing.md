# Firmware & Flashing

## What to flash: MeshCore "Companion (USB Serial)"

The BBS host node (the Heltec V3 wired to the server) must run the MeshCore
**Companion (USB Serial)** firmware variant. This is the variant that speaks the
Companion Radio Protocol documented in docs/03-protocol.md over USB serial — exactly what
our V daemon drives.

- NOT Companion (BLE) — that's for phone clients.
- NOT Companion (Wi-Fi) — exposes the protocol over TCP (see transport doc; we use serial).
- NOT Repeater, NOT Room Server — see the role decision below.

## Design decision: Companion as the PLATFORM foundation (IMPORTANT)

MeshCore has three device roles: Companion, Repeater, and Room Server. The
**Room Server is MeshCore's built-in store-and-forward bulletin board / shared room** —
a fixed, firmware-baked application with a fixed UX.

The strategic framing: this project is not just one app, it's a **broader
application/ecosystem** we own. That ambition decides the role.

- **Companion (USB Serial) is an INTERFACE, not an app.** It hands our daemon the raw
  send/receive primitives. On top of it we can build MANY apps: the retro BBS (app #1),
  telemetry, remote-control services, the MeshCore<->Meshtastic bridge, and the future
  encoded app-protocol + React Native ecosystem. **Companion is the platform foundation.**

- **Room Server is just ONE app pattern** — a shared bulletin room. It's fine as a
  concept (it validates the idea and users may know it), but it's a fixed firmware app we
  don't control or extend. We can offer a Room-Server-LIKE experience as one app in our
  own ecosystem, done our way, WITHOUT being limited to its model.

**Decision: flash Companion (USB Serial) and build our own daemon/platform on top.**
This is the only role that supports an extensible ecosystem rather than a single
fixed app. We are building our own thing; "a room server" is one thing that thing can do,
not the ceiling.

## Flashing procedure (web flasher — easiest)

1. Use Chrome or Edge (Web Serial API required; Firefox/Safari won't work).
2. Go to the official flasher: https://flasher.meshcore.co.uk/ (or meshcore.io/flasher).
3. Plug in the Heltec V3 via USB-C.
4. Driver: Heltec V3 uses a SiLabs CP2102/CP2104 USB-serial chip.
   - FreeBSD: handled natively by the `uslcom` driver; appears as /dev/cuaU0.
   - Linux: appears as /dev/ttyUSB0 (cp210x driver, usually built in).
   - If it doesn't enumerate, install the SiLabs CP210x VCP driver.
5. Select: board = Heltec V3, variant = Companion (USB Serial), region = US915
   (902-928 MHz). Region matters legally and for interop — set it correctly.
6. Flash. First-time = normal/full flash. (The "don't erase / use upgrade.bin" warnings
   seen in some gists apply only when UPGRADING an existing install to preserve
   partitioning — not needed for a fresh install.)
7. Some boards need a physical RESET press to boot the new firmware.

## Verify the flash

- Serial terminal at 115200 baud on /dev/cuaU0 (FreeBSD), OR
- Official web client at app.meshcore.nz / config.meshcore.io.
- If you can talk to the node there, the V daemon can too (same protocol).

## Node count for testing

- Phase 0 needs ONE Companion node (the host, wired to the FreeBSD box).
- Realistic BBS testing needs a SECOND node (a "user" logging in from another radio).
  Plan on flashing a second Heltec as a user/companion for end-to-end session tests.
  (A stock MeshCore phone app on BLE firmware can also act as a test user, since the BBS
  speaks plain text messages in the text-BBS presentation.)
