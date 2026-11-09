# Link scan: signal and delay between repeaters

The BBS measures the link between every pair of repeaters it has heard, not only the ones it can hear itself, and keeps the SNR in each
direction and the one-way delay. It runs four times a day (03:00, 09:00, 15:00, 21:00 local) and whenever the sysop asks.

## How a measurement works

The radio can send a **trace**: a packet that names the repeaters it must pass through (by the first bytes of their public keys). Each repeater
on the list adds the SNR it heard the packet with and passes it on; the radio reports the list back with an SNR per hop and its own for the
last leg. A trace that goes out through a route and straight back (`[A, B, A]`) measures every hop of the route in **both directions**.

To reach a link between two repeaters far from the BBS the scan walks out along links it has already proved: the probe for the link X-Y is the
route to X, then Y, then the route backwards. So the scan:

1. tries every heard repeater straight from the BBS (the ones that answer are its neighbours);
2. then tries each remaining candidate link from whichever end is reachable, nearest first, and from the other end if that fails once;
3. records the SNR of every hop each answered trace crossed, and the delay of the link it was sent to measure;
4. stops when nothing more can be tried, or after 600 probes, with 4 s between probes.

Which pairs are candidates comes from the paths of packets the radio hears: two names side by side in a path could hear each other
(`bbs/linkscan_graph.v`, kept in `path_pairs`). A name that fits several repeaters stands for each of them and the probe settles which link is real.
No hop limit: the only limit is that the names fit in one trace packet (120 bytes).

**Delay** is worked out from round trips: the probe for X-Y goes the same way as the one that first reached X and adds X to Y and Y to X, so the
extra time is two hops. It includes the pause each repeater adds before sending on (they hold packets back a random moment so neighbours do not
collide), so it is the delay a packet really meets, not only airtime.

## Using it

- DM the BBS `LINKS`: link count, the weakest, strongest and slowest links, and when the last scan ran.
- Sysop: `LINKSCAN` queues a scan now.
- Web UI **Links** page: every link with both SNRs, delay (average, min-max), hops from the BBS, how often it answered, and a **Scan now** button.
  The page and the daemon only share the database: the button inserts a `link_scans` row with state `requested`.

## What it costs

Each probe is one short trace packet that crosses the route twice, answered by one push. A scan of a few dozen repeaters is a few hundred packets
over some minutes. The daemon's loop sends one probe per turn and waits for its answer (up to 30 s), so queued messages wait during a scan; DMs
are still answered. A repeater that is not heard costs one timeout (about 3-10 s).

## Layout

| File | Role |
|---|---|
| `bbs/linkscan_plan.v` | pure: name size, probe routes, scan state machine, SNR and delay maths |
| `bbs/linkscan_graph.v` | pure: packet path decoding, the pairs seen side by side, candidate links |
| `bbs/linkscan_run.v` | the four daily slots, picking the repeaters, one probe per tick, recording; `TraceRadio` interface |
| `bbs/linkscan_radio.v` | the real `TraceRadio` over the `meshcore` module (`send_trace_path`, `trace_data` event) |
| `bbs/linkscan_report.v`, `bbs/cmd_links.v` | `LINKS` / `LINKSCAN` |
| `bbs/store_links.v`, `bbs/models.v` | `link_hops`, `link_edges`, `link_scans`, `path_pairs` |
| `webui/links_ui.v`, `templates/links.html` | the Links page |

Needs the `meshcore` V module with trace support (CMD_SEND_TRACE_PATH and the TRACE_DATA push) and repeaters whose firmware forwards direct traces.

## Not verified yet

Everything above is tested with a pretend mesh; nothing has been sent over a real radio. First things to check on the node: that a trace to a
direct neighbour comes back (and its SNR looks right), that `LOG_RX_DATA` pushes arrive so the path pairs fill up, and that two scans in a row
give similar numbers.
