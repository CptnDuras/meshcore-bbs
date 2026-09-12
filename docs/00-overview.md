# Mesh Gateway + BBS + Bridge — Project Overview

## What this is

A single, long-running daemon (written in V, running on Linux) that connects to one or
more mesh radios over a serial (or, later, other) transport and provides:

1. **Off-grid services** — a store-and-forward BBS/bulletin board, plus lightweight
   command services (weather, check-in/roll-call, "last heard", etc.) that any node on
   the mesh can use by sending short text commands.
2. **A mesh bridge** — relays messages between a MeshCore network and a Meshtastic
   network (and makes the services above reachable from either side).

One daemon, one data model, two capabilities that reinforce each other: the bridge makes
the services twice as useful, and the services give the bridge a reason to exist beyond
raw relay.

## Why it exists (goals, in priority order)

1. **Revenue** — sellable later as a self-hosted appliance to off-grid / prepper / SAR /
   ranch / event communities who already buy this hardware.
2. **Personal itch** — the author runs MeshCore + Meshtastic radios and wants these
   services; author is customer #1 and dogfoods every phase.
3. **Learning / craft** — a well-fit project for V + Linux on constrained hardware
   (Raspberry Pi Zero W).

## Hard constraints that shape every decision

- **Transport is sub-kbps, high-latency, lossy.** No images, no voice, no real-time.
  Everything is delay-tolerant, store-and-forward, tiny payloads (text ≤ 160 bytes per
  MeshCore message).
- **Solo developer, limited time.** Work must be shippable in small increments; each
  phase is independently useful. No big-bang releases.
- **Runs on a Raspberry Pi Zero W (Linux).** Small native binary, modest CPU/RAM. The
  mesh is the bottleneck, not the Pi.
- **Language: V (v0.5.2 confirmed installed).** Favor pure-V, single-binary output, no
  heavy external dependencies.

## Hardware topology (current)

```
[Heltec V3 - MeshCore]  --USB serial-->  [Raspberry Pi Zero W, Linux]  --> V daemon
[Heltec V3 - Meshtastic] --USB serial-->  (same Pi, added in the bridge phase)
```

- Two Heltec V3 radios, one per network, both cabled to the same Pi.
- Author has a custom enclosure with two roof antennas (see `05-hardware-notes.md` for
  the antenna separation analysis — relevant because both radios operate near 915 MHz).

## Non-goals (explicitly out of scope)

- No-code app platform, games — ruled out earlier as poor fits for revenue + solo + time.
- Implementing mesh routing or crypto ourselves — the radios do that. We are a *host
  application* talking to companion-mode radios.
- Rich GUI / fat JS frontend — the admin UI is server-rendered HTML (HTMX), later phase.
- BLE / Wi-Fi transports in v1 — serial only (see `04-transport-and-security.md`).
