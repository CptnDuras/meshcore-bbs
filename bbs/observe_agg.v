module main

import sync

// The planner report's memory of what the radio has heard since the last report: for each repeater or room, how often its advert came in, how
// strongly when it came straight from it, and the fewest hops it took; and which pairs of repeaters were side by side in a path.
//
// Only repeaters and rooms with a verified advert and a position are kept. They are fixed places that a plan is about; a chat client is a person,
// and where they are is theirs to say, so it is never recorded here and never leaves this node.
//
// record() is called from the radio's callback for every packet and must stay cheap and never block: it does nothing at all while the report is off.

const observe_max_nodes = 4000
const observe_max_links = 20000
const observed_roles = ['repeater', 'room']

// NodeAcc is one node's tally for the window.
pub struct NodeAcc {
pub mut:
	pubkey      string
	name        string
	role        string
	lat         f64
	lon         f64
	last_advert i64 // the time inside its newest advert
	last_heard  i64 // when we last heard one
	heard       i64
	// signal readings count only adverts that came straight from the node (no hops): on a longer path the radio measured the last repeater, not the node
	direct_n int
	snr_sum  f64
	snr_min  f64
	snr_max  f64
	rssi_sum f64
	rssi_min f64
	rssi_max f64
	hops_min int = -1
}

// LinkAcc is a pair of repeaters seen side by side in a path. a and b are the hash bytes the packet carried (hex), a < b.
pub struct LinkAcc {
pub mut:
	a    string
	b    string
	n    i64
	last i64
}

pub struct Window {
pub:
	from  i64
	to    i64
	nodes []NodeAcc
	links []LinkAcc
}

pub struct Aggregator {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	on    bool
	since i64
	nodes map[string]NodeAcc
	links map[string]LinkAcc
}

pub fn position_ok(lat f64, lon f64) bool {
	if lat < -90 || lat > 90 || lon < -180 || lon > 180 {
		return false
	}
	return lat > 0.000001 || lat < -0.000001 || lon > 0.000001 || lon < -0.000001
}

// set_on switches recording on or off. Switching off forgets the tally: nothing is kept for a report that will not be sent.
pub fn (mut a Aggregator) set_on(on bool, now i64) {
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	if on == a.on {
		return
	}
	a.on = on
	a.nodes.clear()
	a.links.clear()
	a.since = now
}

fn (mut a Aggregator) is_on() bool {
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	return a.on
}

fn (mut a Aggregator) note_link(x string, y string, ts i64) {
	if x == y {
		return
	}
	lo, hi := if x < y { x, y } else { y, x }
	key := '${lo}|${hi}'
	mut l := a.links[key] or {
		if a.links.len >= observe_max_links {
			return
		}
		LinkAcc{
			a: lo
			b: hi
		}
	}
	l.n++
	l.last = ts
	a.links[key] = l
}

// record takes one heard packet: its time, the signal it arrived with, and its bytes.
pub fn (mut a Aggregator) record(ts i64, snr f64, rssi f64, raw []u8) {
	if !a.is_on() {
		return
	}
	h := split_packet(raw) or { return }
	// decoded (and an advert's signature checked) before the lock is taken: that is the slow part
	advert := if h.ptype == payload_type_advert { parse_advert(h.payload) } else { none }
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	if !a.on {
		return
	}
	for i in 0 .. h.path.len - 1 {
		a.note_link(h.path[i].hex(), h.path[i + 1].hex(), ts)
	}
	adv := advert or { return }
	if adv.role !in observed_roles || !adv.located || !position_ok(adv.lat, adv.lon) {
		return
	}
	if h.path.len > 0 {
		a.note_link(adv.pubkey[..h.hash_size * 2], h.path[0].hex(), ts) // the sender and the first repeater to pass it on
	}
	mut n := a.nodes[adv.pubkey] or {
		if a.nodes.len >= observe_max_nodes {
			return
		}
		NodeAcc{
			pubkey: adv.pubkey
		}
	}
	if adv.timestamp >= n.last_advert || n.name == '' {
		if adv.name != '' || n.name == '' {
			n.name = adv.name
		}
		n.role = adv.role
		n.lat = adv.lat
		n.lon = adv.lon
		n.last_advert = adv.timestamp
	}
	n.heard++
	n.last_heard = ts
	hops := h.path.len
	if n.hops_min < 0 || hops < n.hops_min {
		n.hops_min = hops
	}
	if hops == 0 {
		if n.direct_n == 0 {
			n.snr_min = snr
			n.snr_max = snr
			n.rssi_min = rssi
			n.rssi_max = rssi
		} else {
			n.snr_min = if snr < n.snr_min { snr } else { n.snr_min }
			n.snr_max = if snr > n.snr_max { snr } else { n.snr_max }
			n.rssi_min = if rssi < n.rssi_min { rssi } else { n.rssi_min }
			n.rssi_max = if rssi > n.rssi_max { rssi } else { n.rssi_max }
		}
		n.direct_n++
		n.snr_sum += snr
		n.rssi_sum += rssi
	}
	a.nodes[adv.pubkey] = n
}

// take hands over what has been tallied since the last take (or since recording began) and starts a fresh window.
pub fn (mut a Aggregator) take(now i64) Window {
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	mut nodes := a.nodes.values()
	nodes.sort(a.pubkey < b.pubkey)
	mut links := a.links.values()
	links.sort_with_compare(fn (x &LinkAcc, y &LinkAcc) int {
		kx, ky := x.a + x.b, y.a + y.b
		return if kx < ky {
			-1
		} else if kx > ky {
			1
		} else {
			0
		}
	})
	w := Window{
		from:  a.since
		to:    now
		nodes: nodes
		links: links
	}
	a.nodes.clear()
	a.links.clear()
	a.since = now
	return w
}
