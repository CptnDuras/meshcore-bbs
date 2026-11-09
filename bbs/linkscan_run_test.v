module main

// --- a pretend mesh behind the TraceRadio interface ---

struct MeshLink {
	ms  int
	snr f64
}

const fake_ids = ['aa1111111111', 'bb2222222222', 'cc3333333333']

struct FakeRadio {
	links map[string]MeshLink
mut:
	sent [][]u8
}

// names are one byte (the first of the id): the fake maps each back to the id that starts with it
fn (mut f FakeRadio) trace(hash_size int, hashes []u8) !TraceReply {
	f.sent << hashes.clone()
	assert hash_size == 1
	mut at := link_self
	mut snrs := []f64{}
	mut total := 0
	for h in hashes {
		id := fake_ids.filter(it.starts_with('${h:02x}'))[0] or { return error('no such repeater') }
		l := f.links[edge_key(at, id)] or { return error('no reply') }
		total += l.ms
		snrs << l.snr
		at = id
	}
	l := f.links[edge_key(at, link_self)] or { return error('no reply') }
	return TraceReply{
		rtt_ms:    total + l.ms
		snrs:      snrs
		final_snr: l.snr
	}
}

fn contact(id string, name string, kind int, advert i64) NodeName {
	return NodeName{
		pubkey_prefix: id
		name:          name
		contact_type:  kind
		last_advert:   advert
	}
}

fn seed_names(mut s Store, now i64) {
	s.upsert_node_name('aa1111111111', 'Alpha', 2, now - 100) or { panic(err) }
	s.upsert_node_name('bb2222222222', 'Bravo', 2, now - 100) or { panic(err) }
	s.upsert_node_name('cc3333333333', 'Charlie', 2, now - 100) or { panic(err) }
}

fn new_run_store() Store {
	mut s := new_store('sqlite::memory:') or { panic(err) }
	s.migrate() or { panic(err) }
	return s
}

fn test_scan_due_fires_once_per_slot() {
	// UTC, 2026-11-09 00:00:00 = 1794787200
	day := i64(1794787200)
	assert !scan_due(day + 2 * 3600, 0, 0) // 03:00 has not come yet
	assert !scan_due(day + 3 * 3600 + 3600, 0, 0) // a slot missed an hour ago is not run late
	assert scan_due(day + 3 * 3600, 0, 0) // 03:00 has come, never scanned
	assert !scan_due(day + 3 * 3600 + 60, 0, day + 3 * 3600) // already asked at 03:00
	assert !scan_due(day + 8 * 3600, 0, day + 3 * 3600 + 5) // next slot is 09:00
	assert scan_due(day + 9 * 3600, 0, day + 3 * 3600 + 5)
	assert scan_due(day + 21 * 3600 + 1, 0, day + 15 * 3600 + 30)
	// a scan asked for by the sysop at 02:50 does not stop the 03:00 one, but one at 03:10 does
	assert scan_due(day + 3 * 3600, 0, day + 2 * 3600 + 3000)
	assert !scan_due(day + 3 * 3600 + 900, 0, day + 3 * 3600 + 600)
}

fn test_scan_due_uses_local_time() {
	// local midnight in UTC-7 is 07:00 UTC, so 03:00 local is 10:00 UTC
	day := i64(1794787200)
	off := i64(-7 * 3600)
	assert !scan_due(day + 9 * 3600, off, day + 3 * 3600) // 09:00 UTC = 02:00 local: not yet (the 21:00 local slot of yesterday was last)
	assert scan_due(day + 10 * 3600, off, day + 8 * 3600)
}

fn test_repeaters_from_names_keeps_only_recent_repeaters() {
	now := i64(2_000_000_000)
	names := [contact('AA1111111111', 'Alpha', 2, now - 10), // upper case is lower-cased
		contact('bb2222222222', 'Chat', 1, now - 10), // a chat client
		contact('cc3333333333', 'Room', 3, now - 10), // a room server
		contact('dd4444444444', 'Old', 2, now - 15 * 24 * 3600), // gone quiet
		contact('ee55', 'Short', 2, now - 10), // not a full prefix
		contact('ff6666666666', 'NoTime', 2, 0)] // advert time unknown: kept
	reps := repeaters_from_names(names, now)
	assert reps.map(it.id) == ['aa1111111111', 'ff6666666666']
}

fn test_probe_hashes_takes_the_first_bytes_of_each_id() {
	assert probe_hashes(['aa1111111111', 'bb2222222222'], 1)! == [u8(0xaa), 0xbb]
	assert probe_hashes(['aa1111111111'], 2)! == [u8(0xaa), 0x11]
	assert probe_hashes(['aa1111111111'], 4)! == [u8(0xaa), 0x11, 0x11, 0x11]
	if _ := probe_hashes(['aa'], 2) {
		assert false
	}
}

fn run_to_end(mut r LinkScanRunner, mut s Store, mut radio FakeRadio, start i64) i64 {
	mut now := start
	for _ in 0 .. 500 {
		r.tick(now, 0, mut s, mut radio)
		if !r.is_running() && now > start {
			break
		}
		now++
	}
	return now
}

fn test_a_requested_scan_measures_and_records_everything() {
	now := i64(1794787200 + 5 * 3600) // between slots, so only the sysop request can start it
	mut s := new_run_store()
	seed_names(mut s, now)
	// alpha is next to us; bravo is behind alpha; charlie behind bravo. The radio has heard alpha-bravo and bravo-charlie side by side in paths.
	s.merge_path_pairs([SeenPair{'aa', 'bb', 4, now}, SeenPair{'bb', 'cc', 2, now}])!
	mut radio := FakeRadio{
		links: {
			edge_key(link_self, 'aa1111111111'):      MeshLink{100, 9.0}
			edge_key('aa1111111111', 'bb2222222222'): MeshLink{150, 4.0}
			edge_key('bb2222222222', 'cc3333333333'): MeshLink{200, -3.0}
		}
	}
	mut r := LinkScanRunner{
		gap_secs: 0
	}
	// nothing happens between slots without a request
	r.tick(now, 0, mut s, mut radio)
	assert !r.is_running()
	s.request_link_scan('sysop', now)!
	end := run_to_end(mut r, mut s, mut radio, now)
	assert !r.is_running()
	assert end > now
	scan := s.recent_link_scans(1)[0]
	assert scan.state == 'done'
	assert scan.repeaters == 3 && scan.reached == 3
	assert scan.replies >= 3 && scan.probes >= scan.replies
	edges := s.list_link_edges()
	find := fn [edges] (a string, b string) LinkEdge {
		x, y := if a < b { a, b } else { b, a }
		for e in edges {
			if e.a_id == x && e.b_id == y {
				return e
			}
		}
		return LinkEdge{}
	}
	// delay of each link comes out as that link's own one way time, even though bravo-charlie was measured through alpha and bravo
	assert find(link_self, 'aa1111111111').lat_last_ms == 100
	assert find('aa1111111111', 'bb2222222222').lat_last_ms == 150
	assert find('bb2222222222', 'cc3333333333').lat_last_ms == 200
	assert find('aa1111111111', 'bb2222222222').depth == 2
	assert find('bb2222222222', 'cc3333333333').depth == 3
	// the SNR of both directions of the far link was recorded from the probe through it
	hops := s.list_link_hops()
	assert hops.filter(it.from_id == 'bb2222222222' && it.to_id == 'cc3333333333')[0].snr_last == -3.0
	assert hops.filter(it.from_id == 'cc3333333333' && it.to_id == 'bb2222222222')[0].snr_last == -3.0
}

fn test_a_dead_repeater_is_a_miss_not_a_failure_of_the_scan() {
	now := i64(1794787200 + 5 * 3600)
	mut s := new_run_store()
	seed_names(mut s, now)
	mut radio := FakeRadio{
		links: {
			edge_key(link_self, 'aa1111111111'): MeshLink{100, 9.0}
		}
	}
	mut r := LinkScanRunner{
		gap_secs: 0
	}
	s.request_link_scan('sysop', now)!
	run_to_end(mut r, mut s, mut radio, now)
	scan := s.recent_link_scans(1)[0]
	assert scan.state == 'done'
	assert scan.reached == 1
	missed := s.list_link_edges().filter(it.oks == 0)
	assert missed.len == 2 // bravo and charlie never answered
}

fn test_probes_are_spaced_by_the_gap() {
	now := i64(1794787200 + 5 * 3600)
	mut s := new_run_store()
	seed_names(mut s, now)
	mut radio := FakeRadio{
		links: {
			edge_key(link_self, 'aa1111111111'): MeshLink{100, 9.0}
		}
	}
	mut r := LinkScanRunner{
		gap_secs: 10
	}
	s.request_link_scan('sysop', now)!
	r.tick(now, 0, mut s, mut radio) // starts
	r.tick(now, 0, mut s, mut radio) // first probe
	assert radio.sent.len == 1
	r.tick(now + 5, 0, mut s, mut radio)
	assert radio.sent.len == 1 // too soon
	r.tick(now + 10, 0, mut s, mut radio)
	assert radio.sent.len == 2
}

fn test_a_slot_starts_a_scan_by_itself_once() {
	day := i64(1794787200)
	now := day + 3 * 3600 + 30
	mut s := new_run_store()
	seed_names(mut s, now)
	mut radio := FakeRadio{
		links: {
			edge_key(link_self, 'aa1111111111'): MeshLink{100, 9.0}
		}
	}
	mut r := LinkScanRunner{
		gap_secs: 0
	}
	end := run_to_end(mut r, mut s, mut radio, now)
	scans := s.recent_link_scans(10)
	assert scans.len == 1
	assert scans[0].source == 'schedule'
	// the slot has been used: a later tick in the same hour starts nothing
	r.tick(end + 60, 0, mut s, mut radio)
	assert !r.is_running()
	assert s.recent_link_scans(10).len == 1
}

fn test_a_scan_with_no_repeaters_finishes_at_once() {
	now := i64(1794787200 + 5 * 3600)
	mut s := new_run_store()
	mut radio := FakeRadio{}
	mut r := LinkScanRunner{
		gap_secs: 0
	}
	s.request_link_scan('sysop', now)!
	run_to_end(mut r, mut s, mut radio, now)
	assert s.recent_link_scans(1)[0].state == 'done'
	assert radio.sent.len == 0
}

fn test_before_start_runs_once_as_a_scan_begins() {
	now := i64(1794787200 + 5 * 3600)
	mut s := new_run_store()
	mut radio := FakeRadio{}
	mut calls := &CallCount{}
	mut r := LinkScanRunner{
		gap_secs:     0
		before_start: fn [mut calls] () {
			calls.n++
		}
	}
	r.tick(now, 0, mut s, mut radio)
	assert calls.n == 0 // nothing is asked for yet
	s.request_link_scan('sysop', now)!
	run_to_end(mut r, mut s, mut radio, now)
	assert calls.n == 1
}

// a closure cannot append to a captured array, so the hook counts through a struct on the heap
struct CallCount {
mut:
	n int
}
