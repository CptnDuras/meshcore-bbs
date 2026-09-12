# Future Direction: Custom Network Stack over LoRa PHY (KISS)

Status: **future exploration — deliberately NOT part of the BBS build.** Recorded so the
vision and reasoning aren't lost. The BBS ships first on the Companion protocol.

## The vision

Use the LoRa radio as a raw physical layer (via the MeshCore **KISS modem firmware**) and
build our OWN network stack (Layer 2/3+) on top — addressing, routing, reliability,
congestion, framing — instead of using MeshCore's built-in mesh networking. This turns the
project from "an app on MeshCore" into "our own mesh networking stack that uses LoRa radios
as the physical layer," with apps (BBS, telemetry, React Native ecosystem) riding on top.

## Accurate layering (so the vision is precise)

- **LoRa radio (SX1262) = true PHY (L1)** — modulation, RF.
- **KISS = thin serial framing** for host<->modem raw frames (NOT a network layer).
- **MeshCore KISS modem firmware** exposes the radio as a raw-packet modem (255-byte MTU)
  plus crypto primitives (Ed25519, X25519, AES-128+HMAC, SHA-256), radio control, telemetry.
- **Our custom stack (L2/L3+)** would sit above KISS and REPLACE MeshCore's routing.

So it's precisely: "use the KISS modem to treat the LoRa radio as a raw PHY, and build our
own network stack above it." MeshCore's routing is replaced by ours, not built upon.

## Prior art / running start

- **openHop** (`openhop_core` + `openhop_repeater`): a Python daemon that implements a
  MeshCore-compatible routing stack on the HOST and drives the radio over multiple backends
  including **KISS serial**. It even has a policy engine (e.g., "drop channel packets over
  two hops") — routing logic living in host software. This is the exact pattern: KISS = raw
  RF backend; routing intelligence in the host daemon.
- openHop demonstrates the model and could be studied, extended, or used as reference. A
  novel stack of our own would put DIFFERENT logic where openHop puts MeshCore routing.

## Why it's exciting

- Full control of the stack: custom addressing/routing/reliability/QoS tuned for LoRa.
- Research playground: delay-tolerant networking, novel mesh routing, custom transport over
  a lossy sub-kbps medium.
- Raises the platform ceiling: apps ride OUR stack; not constrained by MeshCore's messaging
  model or 160-byte text semantics; get 255-byte raw frames + our own framing.

## Cautions (eyes-open)

1. **Reimplementing networking** (addressing, routing, fragmentation, reliability, loop
   prevention, congestion) over a hostile medium (lossy, sub-kbps, high-latency,
   half-duplex, shared). Large systems effort.
2. **Regulatory:** keep it on 915 ISM (license-free). Ham bands / higher power re-introduce
   encryption + identification rules.
3. **Interop:** a novel stack = our own island, NOT the existing MeshCore mesh (unless we
   speak MeshCore's packet format, as openHop does).
4. **Time competition:** this is a DIFFERENT product (a network stack) than the BBS (an app).
   Doing both at once risks shipping neither. BBS first.

## The on-ramp (why building the BBS now helps this later)

The BBS is specced on an **operations-core / transport-abstraction** architecture
(transport behind an interface; app logic above it — see 02-architecture.md). Therefore
swapping the transport later — from "Companion messages" to "our own stack over KISS" — is a
TRANSPORT-LAYER change, not an app rewrite. The BBS becomes the first app that proves the
custom stack. Building the BBS well now IS the groundwork for this vision.

## Firmware note

This track uses the **KISS modem firmware**, which is a DIFFERENT variant than the
Companion (USB Serial) firmware the BBS uses. A radio runs one at a time, so this would be a
separate radio / separate experiment from the BBS host node.
