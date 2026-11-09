module main

import encoding.hex

// Running a link scan: when one is due, which repeaters it covers, and the loop that sends one probe at a time and records what comes back.
// The radio and the database are handed in (TraceRadio, Store), so the whole loop is tested with a pretend mesh. linkscan_radio.v is the real radio.

// Four scans a day, in minutes after local midnight: 03:00, 09:00, 15:00, 21:00. They keep clear of the 07:00 digest and the other daily posts.
const scan_slots = [3 * 60, 9 * 60, 15 * 60, 21 * 60]

// A slot only starts a scan within this long after it: a daemon that was down through a slot does not run it hours late.
const scan_grace_secs = 1800

// Most probes in one scan, and the pause between probes. A probe is a few short packets, but the airtime is shared with everyone on the mesh.
const scan_max_probes = 600
const scan_gap_secs = 4

const contact_type_repeater = 2

// TraceReply is what a trace brought back: the time it took and the SNR heard at each hop. An error means nothing came back in time.
pub struct TraceReply {
pub:
	rtt_ms    int
	snrs      []f64
	final_snr f64
}

// Neighbour is a repeater that answered a zero-hop DISCOVER request: it hears this node directly. heard_snr is what this radio heard its reply
// with, their_snr what it heard the request with, so the two are the SNR of the link in each direction with no repeater in between.
pub struct Neighbour {
pub:
	id        string // first 6 bytes of its key, lower-case hex
	heard_snr f64
	their_snr f64
}

pub interface TraceRadio {
mut:
	trace(hash_size int, hashes []u8) !TraceReply
	// discover asks every repeater in direct range to answer, and returns whoever did within a few seconds
	discover() ![]Neighbour
}

// scan_due says whether one of the four daily slots has just come and no scan has been asked for since it. tz_offset is local time minus UTC in seconds.
pub fn scan_due(now i64, tz_offset i64, last_requested i64) bool {
	local := now + tz_offset
	midnight := local - local % 86400 - tz_offset // today's local midnight, in UTC seconds
	for m in scan_slots {
		slot := midnight + i64(m) * 60
		if slot <= now && now - slot < scan_grace_secs && last_requested < slot {
			return true
		}
	}
	return false
}

// repeaters_from_names picks the repeaters out of the contact names: type repeater, with a full 6 byte key. How long ago one advertised does not
// matter, because the clocks of many repeaters are far off, so their advert times say nothing about whether they are still there.
pub fn repeaters_from_names(names []NodeName) []Repeater {
	mut out := []Repeater{}
	for n in names {
		id := n.pubkey_prefix.to_lower()
		if n.contact_type != contact_type_repeater || id.len != 12 {
			continue
		}
		out << Repeater{
			id:   id
			name: n.name
		}
	}
	return out
}

// probe_hashes turns the repeater ids on a probe's path into the bytes the trace names them by.
pub fn probe_hashes(path []string, size int) ![]u8 {
	mut out := []u8{}
	for id in path {
		if id.len < size * 2 {
			return error('repeater id ${id} is shorter than a ${size} byte name')
		}
		out << hex.decode(id[..size * 2])!
	}
	return out
}

// LinkScanRunner holds the scan in progress, if any.
pub struct LinkScanRunner {
pub mut:
	gap_secs int         = scan_gap_secs
	log      fn (string) = fn (s string) {}
	// before_start runs as a scan begins, before it reads the pairs of repeaters seen side by side (the daemon saves what it has collected here)
	before_start fn () = fn () {}
mut:
	running  bool
	scan_id  int
	scanner  Scanner
	next_at  i64
	repeater []Repeater
}

pub fn (r &LinkScanRunner) is_running() bool {
	return r.running
}

// tick does whatever is due: starts a scan that was asked for or that a slot calls for, sends the next probe of a running one, or wraps it up.
pub fn (mut r LinkScanRunner) tick(now i64, tz_offset i64, mut store Store, mut radio TraceRadio) {
	if !r.running {
		last := store.recent_link_scans(1)
		if last.len == 0 || last[0].state == 'done' {
			if scan_due(now, tz_offset, if last.len > 0 { last[0].requested } else { i64(0) }) {
				store.request_link_scan('schedule', now) or { return }
			}
		}
		pending := store.pending_link_scan() or {
			r.run_route_test(now, mut store, mut radio)
			return
		}
		r.begin(pending.id, now, mut store, mut radio)
		return
	}
	if now < r.next_at {
		return
	}
	p := r.scanner.next() or {
		r.finish(now, mut store)
		return
	}
	hashes := probe_hashes(p.path, r.scanner.hash_size) or {
		r.scanner.record(p, ProbeResult{}) // cannot be named: counts as no answer
		return
	}
	reply := radio.trace(r.scanner.hash_size, hashes) or {
		TraceReply{
			rtt_ms: -1
		}
	}
	res := if reply.rtt_ms < 0 {
		ProbeResult{}
	} else {
		ProbeResult{
			ok:        true
			rtt_ms:    reply.rtt_ms
			snrs:      reply.snrs
			final_snr: reply.final_snr
		}
	}
	r.note(p, res, now, mut store)
	r.scanner.record(p, res)
	r.next_at = now + r.gap_secs
}

// route_there_and_back adds the way home: a trace only returns to us if its path leads back, so [a, b, c] is sent as [a, b, c, b, a]. The
// SNRs that come back are then those of every leg out and every leg home.
fn route_there_and_back(route []string) []string {
	mut path := route.clone()
	for i := route.len - 2; i >= 0; i-- {
		path << route[i]
	}
	return path
}

// run_route_test sends the oldest queued route test, one per gap, when no scan is running. A route that cannot be named counts as no answer.
fn (mut r LinkScanRunner) run_route_test(now i64, mut store Store, mut radio TraceRadio) {
	if now < r.next_at {
		return
	}
	t := store.pending_route_test() or { return }
	if t.hash_size !in [1, 2, 4] {
		store.finish_route_test(t.id, now, TraceReply{}, false) or {}
		return
	}
	hashes := probe_hashes(route_there_and_back(t.route.split(',')), t.hash_size) or {
		store.finish_route_test(t.id, now, TraceReply{}, false) or {}
		return
	}
	reply := radio.trace(t.hash_size, hashes) or {
		TraceReply{
			rtt_ms: -1
		}
	}
	store.finish_route_test(t.id, now, reply, reply.rtt_ms >= 0) or {}
	r.next_at = now + r.gap_secs
}

// direct_pass asks the repeaters in direct range to answer and records the SNR both ways of each of those links. No repeater is between us, so
// these readings are plain measurements, not something worked out from a trace.
fn (r &LinkScanRunner) direct_pass(now i64, mut store Store, mut radio TraceRadio) {
	heard := radio.discover() or {
		r.log('[links] direct discover failed: ${err}')
		return
	}
	for n in heard {
		store.record_link_hop(n.id, link_self, n.heard_snr, now) or {}
		store.record_link_hop(link_self, n.id, n.their_snr, now) or {}
	}
	r.log('[links] ${heard.len} repeater(s) answered a direct discover')
}

fn (mut r LinkScanRunner) begin(id int, now i64, mut store Store, mut radio TraceRadio) {
	r.before_start()
	r.direct_pass(now, mut store, mut radio)
	pairs := store.list_path_pairs()
	r.repeater = repeaters_from_names(store.list_node_names(8000))
	observed := candidate_edges(pairs, r.repeater)
	r.scanner = new_scanner(r.repeater, observed, scan_max_probes)
	r.scan_id = id
	r.running = true
	r.next_at = now
	store.set_link_scan_running(id, now) or {}
	r.log('[links] scan #${id}: ${r.repeater.len} repeater(s), ${observed.len} candidate link(s), ${r.scanner.hash_size} byte names')
}

fn (mut r LinkScanRunner) finish(now i64, mut store Store) {
	sum := r.scanner.summary()
	store.finish_link_scan(r.scan_id, now, sum) or {}
	r.running = false
	r.log('[links] scan #${r.scan_id} done: reached ${sum.reached}/${sum.repeaters} repeaters, ${sum.replies}/${sum.probes} probes answered')
}

// note records what one probe showed: the SNR of every hop it crossed, and the delay of the link it was sent to measure.
fn (r &LinkScanRunner) note(p Probe, res ProbeResult, now i64, mut store Store) {
	if !res.ok {
		store.record_link_edge(p.via, p.target, false, 0, p.depth, now) or {}
		return
	}
	for h in hop_readings(p.path, res.snrs, res.final_snr) {
		store.record_link_hop(h.from, h.to, h.snr, now) or {}
	}
	store.record_link_edge(p.via, p.target, true, hop_latency_ms(res.rtt_ms, p.base_rtt_ms), p.depth,
		now) or {}
}
