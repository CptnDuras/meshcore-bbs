module main

import crypto.ed25519
import encoding.binary

// The planner report: decoding adverts and paths, the tally, the document, and delivery with a fake poster and an in-memory store.

struct Sender {
	pub_key  ed25519.PublicKey
	priv_key ed25519.PrivateKey
}

fn new_sender() Sender {
	p, s := ed25519.generate_key() or { panic(err) }
	return Sender{
		pub_key:  p
		priv_key: s
	}
}

// app data for an advert: kind, optional position, optional name
fn app_data(kind u8, lat f64, lon f64, located bool, name string) []u8 {
	mut flags := kind
	mut out := []u8{}
	if located {
		flags |= 0x10
	}
	if name != '' {
		flags |= 0x80
	}
	out << flags
	if located {
		mut b := []u8{len: 4}
		binary.little_endian_put_u32(mut b, u32(int(lat * 1000000)))
		out << b
		binary.little_endian_put_u32(mut b, u32(int(lon * 1000000)))
		out << b
	}
	out << name.bytes()
	return out
}

fn (s Sender) advert_payload(ts u32, app []u8) []u8 {
	mut tsb := []u8{len: 4}
	binary.little_endian_put_u32(mut tsb, ts)
	mut msg := []u8{}
	msg << s.pub_key
	msg << tsb
	msg << app
	sig := ed25519.sign(s.priv_key, msg) or { panic(err) }
	mut out := []u8{}
	out << s.pub_key
	out << tsb
	out << sig
	out << app
	return out
}

// a flood packet (route 1) of the given type, through the given one-byte repeaters
fn packet(ptype int, hops []u8, payload []u8) []u8 {
	mut raw := [u8(ptype << 2 | 1)]
	raw << u8(hops.len)
	raw << hops
	raw << payload
	return raw
}

fn (s Sender) advert(ts u32, kind u8, lat f64, lon f64, name string, hops []u8) []u8 {
	return packet(4, hops, s.advert_payload(ts, app_data(kind, lat, lon, true, name)))
}

// --- decoding ---

fn test_a_packet_is_split_into_its_path_and_payload() {
	h := split_packet(packet(4, [u8(0xa1), 0xb2], [u8(9), 9, 9])) or { panic('did not parse') }
	assert h.ptype == 4
	assert h.hash_size == 1
	assert h.path.len == 2
	assert h.path[0] == [u8(0xa1)]
	assert h.path[1] == [u8(0xb2)]
	assert h.payload == [u8(9), 9, 9]
}

fn test_packets_with_transport_codes_and_bigger_hashes_are_split_too() {
	// route 0 (transport flood): four code bytes, then the path length byte; 0x42 = two hops of three bytes
	raw := [u8(0x10), 1, 2, 3, 4, 0x82, 1, 1, 1, 2, 2, 2, 7]
	h := split_packet(raw) or { panic('did not parse') }
	assert h.hash_size == 3
	assert h.path.len == 2
	assert h.path[1] == [u8(2), 2, 2]
	assert h.payload == [u8(7)]
}

fn test_a_broken_packet_does_not_split() {
	assert split_packet([u8(1), 0]) == none
	assert split_packet([u8(0x11), 0x05, 1, 2]) == none // says five hops, has two bytes
	assert split_packet([u8(0x11), 0xC1, 1, 2, 3]) == none // hash size 4 is reserved
	assert split_packet([u8(0x11), 0x01, 0xAA]) == none // a path and no payload
}

fn test_a_signed_advert_says_who_what_and_where() {
	s := new_sender()
	a := parse_advert(s.advert_payload(1234, app_data(2, 44.348123, -106.700456, true, 'Clear Creek'))) or { panic('rejected') }
	assert a.pubkey == s.pub_key.hex()
	assert a.timestamp == 1234
	assert a.role == 'repeater'
	assert a.name == 'Clear Creek'
	assert a.located
	assert a.lat > 44.3481 && a.lat < 44.3482
	assert a.lon < -106.7004 && a.lon > -106.7005
}

fn test_an_advert_without_a_position_or_a_name_still_parses() {
	s := new_sender()
	a := parse_advert(s.advert_payload(1, app_data(3, 0, 0, false, ''))) or { panic('rejected') }
	assert a.role == 'room'
	assert !a.located
	assert a.name == ''
}

fn test_a_forged_advert_is_thrown_away() {
	s := new_sender()
	mut p := s.advert_payload(1234, app_data(2, 44.0, -106.0, true, 'Honest'))
	p[p.len - 1] ^= 0x01 // one changed bit in the name
	assert parse_advert(p) == none
	mut q := s.advert_payload(1234, app_data(2, 44.0, -106.0, true, 'Honest'))
	q[33] ^= 0x01 // or in the timestamp
	assert parse_advert(q) == none
	assert parse_advert([u8(1), 2, 3]) == none
}

fn test_a_name_that_is_not_text_is_dropped_not_passed_on() {
	s := new_sender()
	mut app := app_data(2, 44.0, -106.0, true, 'x')
	app[app.len - 1] = 0xff // not UTF-8
	a := parse_advert(s.advert_payload(1, app)) or { panic('rejected') }
	assert a.name == ''
}

// --- the tally ---

fn on_agg() &Aggregator {
	mut a := &Aggregator{}
	a.set_on(true, 1000)
	return a
}

fn test_nothing_is_kept_while_the_report_is_off() {
	s := new_sender()
	mut a := &Aggregator{}
	a.record(1000, -5, -100, s.advert(1, 2, 44.0, -106.0, 'A', []))
	w := a.take(2000)
	assert w.nodes.len == 0
}

fn test_an_advert_is_tallied_and_direct_ones_give_the_signal() {
	s := new_sender()
	mut a := on_agg()
	a.record(1100, -4, -100, s.advert(10, 2, 44.0, -106.0, 'Hill', []))
	a.record(1200, -8, -110, s.advert(11, 2, 44.0, -106.0, 'Hill', []))
	a.record(1300, 3, -60, s.advert(12, 2, 44.0, -106.0, 'Hill', [u8(0xaa), 0xbb])) // came through two repeaters: its signal says nothing about Hill
	w := a.take(2000)
	assert w.from == 1000
	assert w.to == 2000
	assert w.nodes.len == 1
	n := w.nodes[0]
	assert n.name == 'Hill'
	assert n.heard == 3
	assert n.direct_n == 2
	assert n.snr_min == -8
	assert n.snr_max == -4
	assert n.snr_sum == -12
	assert n.hops_min == 0
	assert n.last_heard == 1300
	assert n.last_advert == 12
}

fn test_the_fewest_hops_and_no_signal_when_never_heard_directly() {
	s := new_sender()
	mut a := on_agg()
	a.record(1100, -4, -100, s.advert(10, 2, 44.0, -106.0, 'Far', [u8(1), 2, 3]))
	a.record(1200, -4, -100, s.advert(11, 2, 44.0, -106.0, 'Far', [u8(1)]))
	n := a.take(2000).nodes[0]
	assert n.hops_min == 1
	assert n.direct_n == 0
}

fn test_clients_and_unplaced_nodes_are_never_kept() {
	s := new_sender()
	c := new_sender()
	mut a := on_agg()
	a.record(1100, -4, -100, c.advert(10, 1, 44.0, -106.0, 'A person', [])) // chat client
	a.record(1100, -4, -100, s.advert(10, 2, 0.0, 0.0, 'No fix', [])) // repeater with no position
	a.record(1100, -4, -100, packet(4, [], s.advert_payload(10, app_data(2, 0, 0, false, 'No position flag'))))
	assert a.take(2000).nodes.len == 0
}

fn test_a_forged_advert_is_not_tallied() {
	s := new_sender()
	mut a := on_agg()
	mut raw := s.advert(10, 2, 44.0, -106.0, 'Fake', [])
	raw[raw.len - 1] ^= 1
	a.record(1100, -4, -100, raw)
	assert a.take(2000).nodes.len == 0
}

fn test_a_newer_advert_moves_the_node_and_an_older_one_does_not() {
	s := new_sender()
	mut a := on_agg()
	a.record(1100, -4, -100, s.advert(20, 2, 45.0, -107.0, 'New', []))
	a.record(1200, -4, -100, s.advert(10, 2, 44.0, -106.0, 'Old', []))
	n := a.take(2000).nodes[0]
	assert n.name == 'New'
	assert n.lat == 45.0
	assert n.heard == 2
}

fn test_repeaters_side_by_side_in_a_path_are_linked_and_so_is_the_sender() {
	s := new_sender()
	mut a := on_agg()
	a.record(1100, -4, -100, s.advert(10, 2, 44.0, -106.0, 'Hill', [u8(0xb2), 0xa1, 0xc3]))
	a.record(1200, -4, -100, packet(2, [u8(0xa1), 0xb2], [u8(1)])) // a message: only its path is of use
	w := a.take(2000)
	pairs := w.links.map('${it.a}-${it.b}:${it.n}')
	first := s.pub_key.hex()[..2]
	assert 'a1-b2:2' in pairs // seen in both paths, whichever way round
	assert 'a1-c3:1' in pairs
	assert (if first < 'b2' { '${first}-b2:1' } else { 'b2-${first}:1' }) in pairs // the sender and the first repeater after it
}

fn test_a_window_starts_empty_after_it_is_taken() {
	s := new_sender()
	mut a := on_agg()
	a.record(1100, -4, -100, s.advert(10, 2, 44.0, -106.0, 'Hill', []))
	assert a.take(2000).nodes.len == 1
	w := a.take(3000)
	assert w.nodes.len == 0
	assert w.from == 2000
}

fn test_switching_off_forgets_the_tally() {
	s := new_sender()
	mut a := on_agg()
	a.record(1100, -4, -100, s.advert(10, 2, 44.0, -106.0, 'Hill', []))
	a.set_on(false, 1500)
	a.set_on(true, 1600)
	assert a.take(2000).nodes.len == 0
}

// --- the document ---

fn test_the_document_has_the_shape_the_service_reads() {
	s := new_sender()
	mut a := on_agg()
	a.record(1100, -4, -100, s.advert(10, 2, 44.348, -106.7, 'Quote " and \\ and\nnewline', []))
	a.record(1100, -4, -100, s.advert(10, 2, 44.348, -106.7, 'Quote " and \\ and\nnewline', [
		u8(1),
		2,
	]))
	w := a.take(2000)
	cfg := ReportConfig{
		iata:            'BYG'
		located:         true
		lat:             44.3
		lon:             -106.7
		public_position: true
	}
	doc := report_json('batch-1', 2000, MqttIdentity{ origin: 'MESHBBS', origin_id: 'AB'.repeat(32) }, cfg, ObserverRadio{ freq: 910.525, bw: 62.5, sf: 8, cr: 5, dbm: 22 }, w)
	j := parse_json(doc) or { panic('the document is not JSON: ${doc}') }
	assert j.get('schema').s == '1'
	assert j.str_of('batch') == 'batch-1'
	ob := j.get('observer')
	assert ob.str_of('name') == 'MESHBBS'
	assert ob.str_of('pubkey') == 'ab'.repeat(32)
	assert ob.str_of('iata') == 'BYG'
	assert ob.get('public_position').s == 'true'
	assert ob.get('radio').get('freq').s == '910.525'
	assert ob.get('radio').get('sf').s == '8'
	assert j.get('nodes').arr.len == 1
	n := j.get('nodes').arr[0]
	assert n.str_of('name') == 'Quote " and \\ and\nnewline' // escaped on the way out, restored on the way in
	assert n.str_of('role') == 'repeater'
	assert n.get('heard').s == '2'
	assert n.get('hops_min').s == '0'
	assert n.get('snr').get('avg').s == '-4.0'
	assert j.get('links').arr.len == 2 // 1-2 in the path, and the sender with the first of them
}

fn test_the_position_stays_out_of_the_document_unless_it_was_given_and_allowed() {
	w := Window{}
	ident := MqttIdentity{
		origin:    'N'
		origin_id: 'AB'.repeat(32)
	}
	none_given := report_json('batch-1', 1, ident, ReportConfig{ public_position: true }, ObserverRadio{}, w)
	assert !none_given.contains('"lat"')
	assert none_given.contains('"public_position":false') // nothing to show, so nothing is public
	private := report_json('batch-1', 1, ident, ReportConfig{ located: true, lat: 44.3, lon: -106.7 }, ObserverRadio{}, w)
	assert private.contains('"lat":44.300000')
	assert private.contains('"public_position":false')
}

fn test_a_node_never_heard_directly_reports_no_signal() {
	n := NodeAcc{
		pubkey:   'ab'.repeat(32)
		name:     'x'
		role:     'room'
		lat:      1
		lon:      2
		heard:    4
		hops_min: 2
	}
	j := parse_json(node_json(n)) or { panic('not JSON') }
	assert j.get('snr').get('avg').s == '0'
	assert j.get('snr').get('max').s == '0'
}

fn test_the_curl_command_keeps_the_token_off_the_command_line() {
	cmd := curl_command('https://x.example/planner-api/ingest', '/tmp/h', '/tmp/b', '/tmp/o')
	assert cmd.contains("-H '@/tmp/h'")
	assert cmd.contains("--data-binary '@/tmp/b'")
	assert cmd.ends_with("'https://x.example/planner-api/ingest'")
	assert !cmd.contains('Token')
}

// --- delivery ---

struct FakePoster {
mut:
	replies []PostReply // answers to give, in order; the last repeats
	seen    []string
	tokens  []string
}

fn (mut f FakePoster) post(url string, token string, body string) PostReply {
	f.seen << body
	f.tokens << token
	return if f.replies.len > 1 { f.replies.pop_left() } else { f.replies[0] }
}

// runs the job at once, on the calling thread
struct InlineLauncher {}

fn (l InlineLauncher) launch(job fn ()) {
	job()
}

struct ReportRig {
mut:
	store    Store
	poster   &FakePoster
	reporter &Reporter
	s        Sender
}

fn report_rig(replies []PostReply) ReportRig {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	store.mqtt_set('report_enabled', '1') or { panic(err) }
	store.mqtt_set('report_url', 'https://planner.example/planner-api/ingest') or { panic(err) }
	store.mqtt_set('report_token', 'a-long-enough-token-for-the-test') or { panic(err) }
	store.mqtt_set('report_minutes', '5') or { panic(err) }
	store.mqtt_set('iata', 'byg') or { panic(err) }
	mut poster := &FakePoster{
		replies: replies
	}
	reporter := &Reporter{
		agg:      &Aggregator{}
		poster:   poster
		launcher: InlineLauncher{}
		ident:    MqttIdentity{
			origin:    'MESHBBS'
			origin_id: 'AB'.repeat(32)
		}
	}
	return ReportRig{
		store:    store
		poster:   poster
		reporter: reporter
		s:        new_sender()
	}
}

fn (mut r ReportRig) hear(ts i64, name string) {
	r.reporter.agg.record(ts, -5, -100, r.s.advert(u32(ts), 2, 44.0, -106.0, name, []))
}

fn (r ReportRig) state() string {
	mut st := r.store
	return st.mqtt_get('report_state') or { '' }
}

fn test_a_window_is_posted_when_it_is_due_with_the_token_and_noted() {
	mut r := report_rig([PostReply{ status: 200 }])
	r.reporter.tick(1000, mut r.store) // loads the settings and starts recording
	r.hear(1100, 'Hill')
	r.reporter.tick(1200, mut r.store) // not due yet (5 minutes = 300 s from 1000)
	assert r.poster.seen.len == 0
	r.reporter.tick(1300, mut r.store) // due: posts
	assert r.poster.seen.len == 1
	assert r.poster.tokens[0] == 'a-long-enough-token-for-the-test'
	assert r.poster.seen[0].contains('"name":"Hill"')
	assert r.poster.seen[0].contains('"iata":"BYG"')
	r.reporter.tick(1301, mut r.store) // takes the answer
	assert r.state().starts_with('ok: sent 1 repeater(s)')
	assert r.reporter.pending.len == 0
	r.reporter.tick(1700, mut r.store) // another window with nothing heard: nothing posted
	assert r.poster.seen.len == 1
}

fn test_a_failed_post_is_kept_and_sent_again_under_the_same_batch_id() {
	mut r := report_rig([PostReply{
		err: 'curl failed (exit 6)'
	}, PostReply{
		status: 200
	}])
	r.reporter.tick(1000, mut r.store)
	r.hear(1100, 'Hill')
	r.reporter.tick(1300, mut r.store)
	r.reporter.tick(1301, mut r.store)
	assert r.state().starts_with('error: curl failed')
	assert r.reporter.pending.len == 1
	r.reporter.tick(1310, mut r.store) // too soon: backing off
	assert r.poster.seen.len == 1
	r.reporter.tick(1400, mut r.store) // past the back-off: the same document again
	assert r.poster.seen.len == 2
	assert r.poster.seen[0] == r.poster.seen[1]
	r.reporter.tick(1401, mut r.store)
	assert r.state().starts_with('ok:')
	assert r.reporter.pending.len == 0
}

fn test_a_report_the_service_refuses_as_bad_is_dropped_not_retried() {
	mut r := report_rig([PostReply{ status: 400 }])
	r.reporter.tick(1000, mut r.store)
	r.hear(1100, 'Hill')
	r.reporter.tick(1300, mut r.store)
	r.reporter.tick(1301, mut r.store)
	assert r.reporter.pending.len == 0
	assert r.state().contains('refused')
	r.reporter.tick(2000, mut r.store)
	assert r.poster.seen.len == 1
}

fn test_a_wrong_token_is_kept_to_be_retried_once_the_owner_fixes_it() {
	mut r := report_rig([PostReply{ status: 401 }])
	r.reporter.tick(1000, mut r.store)
	r.hear(1100, 'Hill')
	r.reporter.tick(1300, mut r.store)
	r.reporter.tick(1301, mut r.store)
	assert r.reporter.pending.len == 1
	assert r.state().contains('401')
}

fn test_nothing_is_recorded_or_sent_while_it_is_off_or_half_set_up() {
	mut r := report_rig([PostReply{ status: 200 }])
	r.store.mqtt_set('report_enabled', '0') or { panic(err) }
	r.reporter.tick(1000, mut r.store)
	r.hear(1100, 'Hill')
	r.reporter.tick(1400, mut r.store)
	assert r.poster.seen.len == 0
	assert r.state() == 'off'
	r.store.mqtt_set('report_enabled', '1') or { panic(err) }
	r.store.mqtt_set('report_token', 'short') or { panic(err) }
	r.reporter.tick(1500, mut r.store)
	assert r.state().starts_with('waiting: set an https address and a token')
	r.hear(1600, 'Hill')
	r.reporter.tick(2000, mut r.store)
	assert r.poster.seen.len == 0
}

fn test_the_backlog_is_bounded() {
	mut r := report_rig([PostReply{ status: 503 }])
	r.reporter.tick(0, mut r.store)
	mut t := i64(0)
	for i in 0 .. 12 {
		t += 300
		r.hear(t - 10, 'Hill ${i}')
		r.reporter.tick(t, mut r.store)
		r.reporter.tick(t + 1, mut r.store)
	}
	assert r.reporter.pending.len <= 8
}

fn test_a_ready_report_says_it_is_on_before_anything_is_sent() {
	mut r := report_rig([PostReply{ status: 200 }])
	r.store.mqtt_set('report_state', 'off') or { panic(err) } // what an earlier run left behind
	r.reporter.tick(1000, mut r.store)
	assert r.state().starts_with('on: reporting every 5 minutes')
}
