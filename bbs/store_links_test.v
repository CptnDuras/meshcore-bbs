module main

fn new_test_store() Store {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	return store
}

fn test_link_hop_keeps_each_direction_apart_and_averages() {
	mut s := new_test_store()
	s.record_link_hop('aa', 'bb', 4.0, 100)!
	s.record_link_hop('aa', 'bb', 8.0, 200)!
	s.record_link_hop('bb', 'aa', -2.0, 300)!
	hops := s.list_link_hops()
	assert hops.len == 2
	ab := hops.filter(it.from_id == 'aa')[0]
	assert ab.n == 2
	assert ab.snr_sum == 12.0
	assert ab.snr_min == 4.0
	assert ab.snr_max == 8.0
	assert ab.snr_last == 8.0
	assert ab.last_ts == 200
	ba := hops.filter(it.from_id == 'bb')[0]
	assert ba.n == 1
	assert ba.snr_last == -2.0
}

fn test_link_edge_is_one_row_whichever_end_is_named_first() {
	mut s := new_test_store()
	s.record_link_edge('bb', 'aa', true, 300, 2, 100)!
	s.record_link_edge('aa', 'bb', true, 100, 1, 200)!
	s.record_link_edge('aa', 'bb', false, 0, 0, 300)!
	edges := s.list_link_edges()
	assert edges.len == 1
	e := edges[0]
	assert e.a_id == 'aa' && e.b_id == 'bb'
	assert e.tries == 3
	assert e.oks == 2
	assert e.lat_n == 2
	assert e.lat_sum_ms == 400
	assert e.lat_min_ms == 100
	assert e.lat_max_ms == 300
	assert e.lat_last_ms == 100
	assert e.depth == 1 // the fewest repeaters in between seen
	assert e.last_ts == 300
	assert e.last_ok_ts == 200
}

fn test_link_edge_failure_alone_records_a_try_and_no_delay() {
	mut s := new_test_store()
	s.record_link_edge('aa', 'bb', false, 0, 0, 50)!
	e := s.list_link_edges()[0]
	assert e.tries == 1 && e.oks == 0 && e.lat_n == 0
	assert e.last_ok_ts == 0
}

fn test_path_pairs_accumulate_across_merges() {
	mut s := new_test_store()
	s.merge_path_pairs([SeenPair{'aa', 'bb', 2, 100}, SeenPair{'bb', 'cc', 1, 100}])!
	s.merge_path_pairs([SeenPair{'aa', 'bb', 3, 200}])!
	mut pairs := s.list_path_pairs()
	pairs.sort(a.a < b.a)
	assert pairs.len == 2
	assert pairs[0] == SeenPair{'aa', 'bb', 5, 200}
	assert pairs[1] == SeenPair{'bb', 'cc', 1, 100}
}

fn test_link_scan_request_lifecycle() {
	mut s := new_test_store()
	assert s.pending_link_scan() == none
	id := s.request_link_scan('sysop', 100)!
	assert id > 0
	// asking again while one waits does not queue a second
	assert s.request_link_scan('schedule', 110)! == id
	p := s.pending_link_scan() or { panic('expected a pending scan') }
	assert p.id == id && p.source == 'sysop' && p.requested == 100
	s.set_link_scan_running(id, 120)!
	assert s.pending_link_scan() == none
	// nor while it runs
	assert s.request_link_scan('sysop', 130)! == id
	s.finish_link_scan(id, 500, Summary{
		repeaters: 9
		reached:   7
		probes:    30
		replies:   18
	})!
	done := s.recent_link_scans(5)[0]
	assert done.state == 'done'
	assert done.started == 120 && done.finished == 500
	assert done.repeaters == 9 && done.reached == 7 && done.probes == 30 && done.replies == 18
	// once done, a new one can be asked for
	assert s.request_link_scan('sysop', 600)! != id
}

fn test_stale_running_scan_is_closed_at_startup() {
	mut s := new_test_store()
	id := s.request_link_scan('schedule', 100)!
	s.set_link_scan_running(id, 110)!
	s.close_stale_link_scans(200)
	r := s.recent_link_scans(1)[0]
	assert r.state == 'done' && r.finished == 200
}

// The web UI reads these tables with plain SQL (webui/links_ui.v, whose test builds them from the same column lists): they must not drift apart.
fn columns_of(mut s SqliteStore, table string) []string {
	rows := s.db.exec('PRAGMA table_info(${table})') or { return []string{} }
	return rows.map(it.vals[1])
}

fn test_link_tables_have_the_columns_the_web_page_reads() {
	mut s := &SqliteStore{
		path: ':memory:'
	}
	s.open()!
	s.migrate()!
	assert columns_of(mut s, 'link_edges') == ['id', 'a_id', 'b_id', 'tries', 'oks', 'lat_n',
		'lat_sum_ms', 'lat_min_ms', 'lat_max_ms', 'lat_last_ms', 'depth', 'last_ts', 'last_ok_ts']
	assert columns_of(mut s, 'link_hops') == ['id', 'from_id', 'to_id', 'n', 'snr_sum', 'snr_min',
		'snr_max', 'snr_last', 'last_ts']
	assert columns_of(mut s, 'link_scans') == ['id', 'requested', 'started', 'finished', 'source',
		'state', 'repeaters', 'reached', 'probes', 'replies']
	assert columns_of(mut s, 'node_names') == ['id', 'pubkey_prefix', 'name', 'contact_type',
		'last_advert', 'updated']
}
