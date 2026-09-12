# Hardware Notes

## Enclosure with two 915 MHz antennas (bridge box)

The bridge box holds two Heltec V3 radios (one MeshCore, one Meshtastic) with two
antennas exiting the top. Both operate in the 902–928 MHz US ISM band, so the antennas
are essentially co-channel neighbors and WILL couple unless separated. This matters
because a transmit burst from radio A can desensitize (or damage the front end of)
radio B if isolation is too low.

### Key numbers at 915 MHz

- Wavelength lambda = c / f = 3e8 / 915e6 ~= 0.328 m ~= **32.8 cm** (~12.9 in).
- Quarter wave ~= 8.2 cm; half wave ~= 16.4 cm; full wave ~= 32.8 cm.

### Isolation vs. separation (far-field, free-space approximation)

For two antennas separated by distance d, free-space path loss (a proxy for isolation
between them when broadside/far-field) is:

    FSPL(dB) = 20*log10(d) + 20*log10(f) - 147.55   (d in meters, f in Hz)

At 915 MHz this gives approximate antenna-to-antenna isolation:

| Separation | ~Isolation | Notes                                             |
|-----------:|-----------:|---------------------------------------------------|
|   ~8 cm    |   ~10 dB   | quarter-wave — far too little, strong coupling    |
|  ~16 cm    |   ~16 dB   | half-wave — minimum sane spacing, still marginal  |
|  ~33 cm    |   ~22 dB   | one wavelength — practical minimum target         |
|  ~50 cm    |   ~26 dB   | comfortable                                        |
|  ~1 m      |   ~32 dB   | good isolation                                     |

(These are approximations; real isolation depends on antenna pattern, orientation, and
nearby metal. Vertical whips are omnidirectional in azimuth, so you can't "aim away".)

### Practical guidance for this box

1. **Aim for >= 1 wavelength (~33 cm / ~13 in) between the two antenna feedpoints** as a
   practical minimum. More is better; there is no penalty for extra spacing except size.
2. **Vertical (stacked) separation beats horizontal separation** for two vertical whips.
   Two vertical antennas side-by-side couple through their strongest (broadside) lobe;
   stacking them one above the other puts each in the other's radiation null (off the end
   of the whip), buying significant extra isolation for the same physical distance.
   If the box form factor allows, offset the antenna heights.
3. **Add TX/RX timing coordination in software.** Because both radios sit inside the
   daemon, the bridge can avoid transmitting on one radio while the other is mid-RX of a
   packet it cares about. This is not a substitute for physical isolation (a TX burst can
   still desense/damage a too-close neighbor), but it reduces collisions once isolation
   is adequate. Design note only; not a Phase 0 concern.
4. **Consider a band/channel offset if possible.** MeshCore and Meshtastic can be
   configured to different sub-band frequencies/channels within 902–928. A few MHz of
   separation lets each radio's front-end filtering help reject the other. Combined with
   physical spacing, this is the cheapest real-world improvement.
5. **Watch TX power.** Heltec V3 can push ~+20–22 dBm. With only ~16 dB isolation, the
   neighbor sees ~ +4 dBm at its antenna — enough to desense and potentially stress the
   LNA. Higher isolation (or lower TX power) directly protects the other receiver.
6. **Keep feedlines and grounds tidy.** Common-mode currents on coax shields and shared
   ground planes can couple energy independent of antenna spacing; route coax away from
   the other antenna and use good connectors.

### Polarization diversity (additional isolation lever)

Polarization offset between the two antennas adds isolation ON TOP of distance/stacking.
But it interacts with the mesh: nearly all Meshtastic/MeshCore nodes use VERTICAL whips,
so any polarization we choose is also measured against a vertical network we must serve.

Ranking of polarization choices for a gateway (goal: hear a vertical mesh in all
directions while keeping the two co-located radios from desensing each other):

1. **±45° slant "V" (RECOMMENDED).** Bend BOTH antennas 45° off vertical in OPPOSITE
   directions, in the SAME vertical plane (a mirror-image "V"). Result:
   - 90° between the two antennas -> ~15-20 dB realistic cross-pol isolation between the
     two radios (adds to distance isolation).
   - Each antenna only 45° off vertical -> ~3 dB down to vertical mesh nodes, and the
     penalty is SYMMETRIC (both radios take the same small hit).
   This is the sweet spot: max offset between the pair, minimal + balanced cost to the
   mesh. Trivial to implement with bendable antennas.

2. **Opposite-sense circular (helical), situational.** RHCP on one, LHCP on the other
   gives ~20 dB rejection between them while each is only ~3 dB down to ANY linear
   (vertical) node. BUT practical 915 MHz axial helicals are bulky and DIRECTIONAL (a
   beam along the axis), which fights the omnidirectional coverage a gateway wants. Only
   worth it if surrounding nodes are clustered in one direction (point the helical at
   them). CP purity also degrades toward elliptical in a cluttered enclosure.

3. **Full 90° cross-pol linear (AVOID).** Leaving one vertical and bending the other to
   horizontal gives great isolation between the two radios but ~20 dB mismatch loss to
   the entire vertical mesh — the horizontal radio goes nearly deaf to normal nodes. Do
   NOT do this on a gateway. (Fine only for a controlled point-to-point link where you
   own and match both ends.)

Implementation details for the ±45° "V":
- Keep both bends in the SAME vertical plane so the between-antenna angle is a clean 90°.
  If one bends forward and the other sideways, the true angle is not 90° and isolation is
  less predictable.
- Slant is ADDITIVE to distance isolation, not a replacement. Coupling is worst at the
  FEEDPOINTS, so still give the feedpoints >= 1 lambda (~33 cm) spacing where they exit
  the box; the bend mainly separates the tips.
- Stacks with channel offset and modest TX power — use all of them together.

### Bottom line

Target **at least one wavelength (~33 cm) of feedpoint separation** (vertically stacked
if possible), set the two antennas in a **±45° slant "V" (opposite directions, same
plane)** for cross-pol isolation at only ~3 dB symmetric cost to the vertical mesh, add a
**few-MHz channel offset** between the two networks, and keep **TX power only as high as
needed**. Avoid full-horizontal (one vertical + one horizontal) — it isolates the pair
but cripples reach to the vertically-polarized mesh. Helical/CP only if nodes are
directionally clustered.

## Radios

- 2x Heltec V3 (ESP32-S3 + SX1262 LoRa), USB-C serial to the Pi.
- One flashed with MeshCore companion_radio_usb firmware; the other with Meshtastic
  (bridge phase).
- ESP32 auto-resets on serial DTR assertion — the daemon must open the port WITHOUT
  toggling DTR (see docs/03-protocol.md and 04-transport-and-security.md).

## Host

- Raspberry Pi Zero W, Linux. Radios on USB. Use /dev/serial/by-id/... stable paths.
- Sensor node (Phase 4) is separate hardware reporting into the mesh, not attached to
  the Pi.
