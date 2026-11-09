module main

// Link scan: measure the signal and the delay between every repeater the radio has heard, not only the ones this node can hear itself.
//
// The radio can send a trace: a packet that names the repeaters it must pass through, in order. Each repeater on the list adds the SNR it heard
// the packet with and sends it on, and the radio reports the list back with an SNR for every hop plus its own for the last leg. A trace that goes
// out through a route to a repeater and comes straight back along the same route therefore measures every hop of that route in both directions.
// To reach a link between two repeaters far from us, the scan walks out along links it has already proved: route to X, then Y, then back.
//
// This file is the pure part: which repeaters to name, what to probe next, and how to turn an answer into numbers. Nothing here touches the radio
// or the database (see linkscan_run.v for that), so all of it is tested without either.

// link_self stands for this node's own end of a link.
pub const link_self = 'self'

// A repeater is named in a trace by the first bytes of its public key. node_names keeps 6 of them (12 hex digits), so 1, 2 or 4 byte names.
const trace_hash_sizes = [1, 2, 4]

// Most bytes of names in one trace. The packet holds 184 bytes of payload and 9 of them are the trace's own header.
const trace_max_hash_bytes = 120

// Repeater is one repeater the scan knows: id is the first 6 bytes of its public key in lower case hex, as node_names keeps it.
pub struct Repeater {
pub:
	id   string
	name string
}

// Edge is an unordered pair of nodes (either may be link_self) that might hear each other.
pub struct Edge {
pub:
	a string
	b string
}

pub fn edge_key(a string, b string) string {
	return if a < b { '${a}|${b}' } else { '${b}|${a}' }
}

// pick_hash_size is the shortest name length (in bytes) that tells every repeater in the list apart. Short names keep the packet, and so the
// airtime of every probe, small. If even the longest collides the longest is used and the odd ambiguous probe simply fails.
pub fn pick_hash_size(ids []string) int {
	for size in trace_hash_sizes {
		mut seen := map[string]bool{}
		mut clash := false
		for id in ids {
			if id.len < size * 2 {
				continue
			}
			p := id[..size * 2]
			if p in seen {
				clash = true
				break
			}
			seen[p] = true
		}
		if !clash {
			return size
		}
	}
	return trace_hash_sizes.last()
}

// Probe is one trace to send: the nodes to pass through, in order, out and back. A route to X is the list of repeaters from this node to X;
// the probe for the link X-Y is route + Y + route backwards, so that the radio hears the answer from the first repeater of the route.
pub struct Probe {
pub:
	path        []string // repeater ids in the order the trace visits them
	via         string   // the end of the link the trace comes from (link_self for a direct neighbour)
	target      string   // the repeater at the far end of the link
	base_rtt_ms int      // round trip time measured to via on an earlier probe, 0 for link_self
	depth       int      // repeaters between this node and target, target included
}

// ProbeResult is what came back for a probe. ok is false when nothing did.
pub struct ProbeResult {
pub:
	ok        bool
	rtt_ms    int
	snrs      []f64 // what each node on the path heard the trace with, in path order
	final_snr f64   // what this node heard the last leg with
}

pub fn probe_path(route []string, target string) []string {
	mut p := route.clone()
	p << target
	for i := route.len - 1; i >= 0; i-- {
		p << route[i]
	}
	return p
}

// HopReading is the SNR one node heard another with, in one direction.
pub struct HopReading {
pub:
	from string
	to   string
	snr  f64
}

// hop_readings reads a trace answer as one reading per hop of the path: hop i went from the node before path[i] (this node for the first) to
// path[i], and the last leg from the last node back to this one. An answer that does not match the path says nothing.
pub fn hop_readings(path []string, snrs []f64, final_snr f64) []HopReading {
	if path.len == 0 || snrs.len != path.len {
		return []HopReading{}
	}
	mut out := []HopReading{}
	for i, id in path {
		out << HopReading{
			from: if i == 0 { link_self } else { path[i - 1] }
			to:   id
			snr:  snrs[i]
		}
	}
	out << HopReading{
		from: path.last()
		to:   link_self
		snr:  final_snr
	}
	return out
}

// hop_latency_ms is the time one hop of a link takes, one way, worked out from round trips. The probe for X-Y goes the same way as the probe that
// first reached X and then adds X to Y and Y to X, so the extra time is two hops. It includes the time Y waits before sending on (repeaters
// hold a packet back a random moment so that neighbours do not collide), so it is the delay a packet really meets, not just airtime.
pub fn hop_latency_ms(rtt_ms int, base_rtt_ms int) int {
	extra := rtt_ms - base_rtt_ms
	return if extra <= 0 { 0 } else { extra / 2 }
}

// Scanner decides what to probe next. It is given the repeaters and the pairs that might be linked and learns routes as probes come back.
pub struct Scanner {
pub:
	hash_size  int
	max_probes int
pub mut:
	probes  int
	replies int
mut:
	edges []Edge
	tried map[string]bool     // "x>y": the probe from x to y has been sent
	done  map[string]bool     // edge key: measured, or no way left to try
	route map[string][]string // repeater id -> the route from this node to it
	rtt   map[string]int      // repeater id -> round trip time to it
}

pub fn new_scanner(repeaters []Repeater, observed []Edge, max_probes int) Scanner {
	ids := repeaters.map(it.id)
	mut edges := []Edge{}
	mut seen := map[string]bool{}
	// every repeater is first tried straight from this node: those that answer are the neighbours the rest are reached through
	for id in ids {
		edges << Edge{link_self, id}
		seen[edge_key(link_self, id)] = true
	}
	for e in observed {
		k := edge_key(e.a, e.b)
		if e.a == e.b || k in seen || e.a !in ids || e.b !in ids {
			continue
		}
		seen[k] = true
		edges << e
	}
	return Scanner{
		hash_size:  pick_hash_size(ids)
		max_probes: max_probes
		edges:      edges
	}
}

fn (s &Scanner) reach(id string) ?[]string {
	if id == link_self {
		return []string{}
	}
	return s.route[id] or { return none }
}

// next returns the next probe, or none when every link has been tried as far as it can be. A link is tried from the end that is nearest to this
// node; if that fails and the other end is also reachable it is tried once from there.
pub fn (mut s Scanner) next() ?Probe {
	if s.probes >= s.max_probes {
		return none
	}
	mut best := -1
	mut best_depth := 0
	mut from := ''
	mut to := ''
	for i, e in s.edges {
		k := edge_key(e.a, e.b)
		if s.done[k] {
			continue
		}
		for dir in 0 .. 2 {
			x, y := if dir == 0 { e.a, e.b } else { e.b, e.a }
			rt := s.reach(x) or { continue }
			if s.tried['${x}>${y}'] || y == link_self {
				continue
			}
			if (rt.len * 2 + 1) * s.hash_size > trace_max_hash_bytes {
				s.tried['${x}>${y}'] = true // too far to name in one packet
				continue
			}
			if best < 0 || rt.len < best_depth {
				best = i
				best_depth = rt.len
				from = x
				to = y
			}
		}
	}
	if best < 0 {
		return none
	}
	rt := s.reach(from) or { []string{} }
	return Probe{
		path:        probe_path(rt, to)
		via:         from
		target:      to
		base_rtt_ms: if from == link_self { 0 } else { s.rtt[from] }
		depth:       rt.len + 1
	}
}

// record takes the answer to a probe given out by next.
pub fn (mut s Scanner) record(p Probe, r ProbeResult) {
	s.probes++
	s.tried['${p.via}>${p.target}'] = true
	k := edge_key(p.via, p.target)
	if r.ok {
		s.replies++
		s.done[k] = true
		if p.target !in s.route || s.route[p.target].len > p.depth {
			s.route[p.target] = p.path[..p.depth].clone()
			s.rtt[p.target] = r.rtt_ms
		}
		return
	}
	// no answer: the link is given up on once it has been tried from both ends, or from this node (the far end cannot try it back)
	if s.tried['${p.target}>${p.via}'] || p.via == link_self {
		s.done[k] = true
	}
}

// Summary is how far a scan got.
pub struct Summary {
pub:
	repeaters int
	reached   int // repeaters that some probe got to
	probes    int
	replies   int
}

pub fn (s &Scanner) summary() Summary {
	return Summary{
		repeaters: s.edges.filter(it.a == link_self).len
		reached:   s.route.len
		probes:    s.probes
		replies:   s.replies
	}
}
