module main

import meshcore
import time

// The real TraceRadio: sends the trace through the radio and waits for the push that carries the same tag.
// The radio hands answers to a callback on the reader thread; they come over a channel to the one waiting here.

const trace_wait_min_ms = 3000
const trace_wait_max_ms = 30000
const trace_wait_margin_ms = 1500

struct TraceArrival {
	at_ms i64
	ev    meshcore.Event
}

pub struct McTrace {
pub mut:
	mc       &meshcore.MeshCore
	arrivals chan TraceArrival   = chan TraceArrival{cap: 16}
	answers  chan meshcore.Event = chan meshcore.Event{cap: 64}
mut:
	tag u32
}

// discover_wait_ms is how long to listen for DISCOVER answers: each repeater waits a random, widened moment before it replies.
const discover_wait_ms = 8000

// attach starts listening for trace answers. Call once after the radio is open.
pub fn (mut t McTrace) attach() {
	arrivals := t.arrivals
	t.mc.subscribe(.trace_data, fn [arrivals] (ev meshcore.Event) {
		a := TraceArrival{
			at_ms: time.ticks()
			ev:    ev
		}
		select {
			arrivals <- a {
			}
			else {
			} // nobody is waiting and the channel is full: the answer is stale anyway
		}
	})
	answers := t.answers
	t.mc.subscribe(.discover_resp, fn [answers] (ev meshcore.Event) {
		select {
			answers <- ev {
			}
			else {
			} // nobody is listening and the channel is full: a stale answer
		}
	})
	t.tag = u32(time.now().unix_nano())
}

// contacts asks the radio for its contact list now and keeps the repeaters that have a full 6 byte key.
pub fn (mut t McTrace) contacts() ![]Repeater {
	all := t.mc.get_contacts(0, 8000)!
	mut out := []Repeater{}
	for c in all {
		id := c.pubkey_prefix.to_lower()
		if c.contact_type == u8(contact_type_repeater) && id.len == 12 {
			out << Repeater{
				id:   id
				name: c.adv_name
			}
		}
	}
	return out
}

// discover sends one zero-hop request and gathers the answers that carry its tag, keeping the last of any node that answers twice.
pub fn (mut t McTrace) discover() ![]Neighbour {
	t.tag++
	tag := t.tag
	for { // forget answers to an earlier request
		select {
			_ := <-t.answers {
			}
			else {
				break
			}
		}
	}
	t.mc.send_discover(tag)!
	deadline := time.ticks() + discover_wait_ms
	mut found := map[string]Neighbour{}
	for time.ticks() < deadline {
		select {
			ev := <-t.answers {
				p := ev.payload
				if p.discover_tag != tag || p.discover_type != meshcore.adv_type_repeater || p.discover_key.len < 6 {
					continue
				}
				id := p.discover_key[..6].hex()
				found[id] = Neighbour{
					id:        id
					heard_snr: p.snr
					their_snr: p.discover_snr
				}
			}
			50 * time.millisecond {
			}
		}
	}
	return found.values()
}

// wait_ms is how long to wait for an answer: what the radio estimated for the trip, with a margin, within sane bounds.
pub fn trace_wait_ms(suggested_ms u32) int {
	w := if suggested_ms > u32(trace_wait_max_ms) { trace_wait_max_ms } else { int(suggested_ms) }
	t := w + trace_wait_margin_ms
	return if t < trace_wait_min_ms {
		trace_wait_min_ms
	} else if t > trace_wait_max_ms {
		trace_wait_max_ms
	} else {
		t
	}
}

pub fn (mut t McTrace) trace(hash_size int, hashes []u8) !TraceReply {
	t.tag++
	tag := t.tag
	for { // forget answers to earlier probes that arrived too late
		select {
			_ := <-t.arrivals {
			}
			else {
				break
			}
		}
	}
	t0 := time.ticks()
	sent := t.mc.send_trace_path(tag, hash_size, hashes)!
	deadline := t0 + trace_wait_ms(sent.payload.suggested_timeout)
	for time.ticks() < deadline {
		select {
			a := <-t.arrivals {
				p := a.ev.payload
				if p.trace_tag != tag || p.trace_hashes != hashes {
					continue
				}
				return TraceReply{
					rtt_ms:    int(a.at_ms - t0)
					snrs:      p.trace_snrs
					final_snr: p.snr
				}
			}
			50 * time.millisecond {
			}
		}
	}
	return error('no answer to trace ${tag}')
}
