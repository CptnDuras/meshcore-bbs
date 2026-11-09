module main

import encoding.hex

// Running a link scan: when one is due, which repeaters it covers, and the loop that sends one probe at a time and records what comes back.
// The radio and the database are handed in (TraceRadio, Store), so the whole loop is tested with a pretend mesh. linkscan_radio.v is the real radio.

// Four scans a day, in minutes after local midnight: 03:00, 09:00, 15:00, 21:00. They keep clear of the 07:00 digest and the other daily posts.
const scan_slots = [3 * 60, 9 * 60, 15 * 60, 21 * 60]

// A slot only starts a scan within this long after it: a daemon that was down through a slot does not run it hours late.
const scan_grace_secs = 1800

// A repeater counts as heard if its advert is no older than this.
const heard_max_age_secs = i64(14 * 24 * 3600)

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

pub interface TraceRadio {
mut:
	trace(hash_size int, hashes []u8) !TraceReply
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

// A name of at least this many hex digits (2 bytes) in a recent path points at one repeater well enough to show it is alive.
const min_alive_name_len = 4

// alive_in_paths says whether a recent path carried a name that starts this id: a repeater that forwards traffic is alive even if its advert is old.
fn alive_in_paths(id string, heard []SeenPair, now i64) bool {
	for p in heard {
		if now - p.last > heard_max_age_secs {
			continue
		}
		for name in [p.a, p.b] {
			if name.len >= min_alive_name_len && id.starts_with(name) {
				return true
			}
		}
	}
	return false
}

// repeaters_from_names picks the repeaters out of the contact names: type repeater, with a full 6 byte key, advertised recently enough or seen
// forwarding in a recent path.
pub fn repeaters_from_names(names []NodeName, heard []SeenPair, now i64) []Repeater {
	mut out := []Repeater{}
	for n in names {
		id := n.pubkey_prefix.to_lower()
		if n.contact_type != contact_type_repeater || id.len != 12 {
			continue
		}
		if n.last_advert > 0 && now - n.last_advert > heard_max_age_secs
			&& !alive_in_paths(id, heard, now) {
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
		pending := store.pending_link_scan() or { return }
		r.begin(pending.id, now, mut store)
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

fn (mut r LinkScanRunner) begin(id int, now i64, mut store Store) {
	r.before_start()
	pairs := store.list_path_pairs()
	r.repeater = repeaters_from_names(store.list_node_names(8000), pairs, now)
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
