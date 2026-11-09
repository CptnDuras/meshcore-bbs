module main

// --- link scan (trace probes between repeaters) ---

pub fn (mut s SqliteStore) record_link_hop(from_id string, to_id string, snr f64, ts i64) ! {
	rows := sql s.db {
		select from LinkHop where from_id == from_id && to_id == to_id limit 1
	} or { []LinkHop{} }
	if rows.len == 0 {
		h := LinkHop{
			from_id:  from_id
			to_id:    to_id
			n:        1
			snr_sum:  snr
			snr_min:  snr
			snr_max:  snr
			snr_last: snr
			last_ts:  ts
		}
		sql s.db {
			insert h into LinkHop
		}!
		return
	}
	h := rows[0]
	id := h.id
	n := h.n + 1
	snr_sum := h.snr_sum + snr
	snr_min := if snr < h.snr_min { snr } else { h.snr_min }
	snr_max := if snr > h.snr_max { snr } else { h.snr_max }
	sql s.db {
		update LinkHop set n = n, snr_sum = snr_sum, snr_min = snr_min, snr_max = snr_max,
		snr_last = snr, last_ts = ts where id == id
	}!
}

// record_link_edge notes one trace tried over the link x-y. lat_ms is the one-way delay it worked out to when it was answered.
pub fn (mut s SqliteStore) record_link_edge(x string, y string, ok bool, lat_ms int, depth int, ts i64) ! {
	a, b := if x < y { x, y } else { y, x }
	rows := sql s.db {
		select from LinkEdge where a_id == a && b_id == b limit 1
	} or { []LinkEdge{} }
	mut e := if rows.len > 0 {
		rows[0]
	} else {
		LinkEdge{
			a_id: a
			b_id: b
		}
	}
	e.tries++
	e.last_ts = ts
	if ok {
		e.oks++
		e.last_ok_ts = ts
		e.lat_sum_ms += lat_ms
		e.lat_last_ms = lat_ms
		e.lat_min_ms = if e.lat_n == 0 || lat_ms < e.lat_min_ms { lat_ms } else { e.lat_min_ms }
		e.lat_max_ms = if lat_ms > e.lat_max_ms { lat_ms } else { e.lat_max_ms }
		e.lat_n++
		e.depth = if e.depth == 0 || depth < e.depth { depth } else { e.depth }
	}
	if rows.len == 0 {
		sql s.db {
			insert e into LinkEdge
		}!
		return
	}
	id := e.id
	sql s.db {
		update LinkEdge set tries = e.tries, oks = e.oks, lat_n = e.lat_n, lat_sum_ms = e.lat_sum_ms,
		lat_min_ms = e.lat_min_ms, lat_max_ms = e.lat_max_ms, lat_last_ms = e.lat_last_ms,
		depth = e.depth, last_ts = e.last_ts, last_ok_ts = e.last_ok_ts where id == id
	}!
}

pub fn (mut s SqliteStore) list_link_hops() []LinkHop {
	return sql s.db {
		select from LinkHop order by from_id
	} or { []LinkHop{} }
}

pub fn (mut s SqliteStore) list_link_edges() []LinkEdge {
	return sql s.db {
		select from LinkEdge order by a_id
	} or { []LinkEdge{} }
}

// merge_path_pairs adds pairs heard since the last merge to the ones kept.
pub fn (mut s SqliteStore) merge_path_pairs(pairs []SeenPair) ! {
	for p in pairs {
		a, b := p.a, p.b
		rows := sql s.db {
			select from PathPair where a == a && b == b limit 1
		} or { []PathPair{} }
		if rows.len == 0 {
			row := PathPair{
				a:    a
				b:    b
				n:    p.n
				last: p.last
			}
			sql s.db {
				insert row into PathPair
			}!
		} else {
			id := rows[0].id
			n := rows[0].n + p.n
			last := p.last
			sql s.db {
				update PathPair set n = n, last = last where id == id
			}!
		}
	}
}

pub fn (mut s SqliteStore) list_path_pairs() []SeenPair {
	rows := sql s.db {
		select from PathPair
	} or { []PathPair{} }
	return rows.map(SeenPair{
		a:    it.a
		b:    it.b
		n:    it.n
		last: it.last
	})
}

// request_link_scan queues a scan for the daemon to run and returns its id. Asking again while one is already waiting or running returns that one.
pub fn (mut s SqliteStore) request_link_scan(source string, now i64) !int {
	waiting := sql s.db {
		select from LinkScan where state == 'requested' limit 1
	} or { []LinkScan{} }
	if waiting.len > 0 {
		return waiting[0].id
	}
	running := sql s.db {
		select from LinkScan where state == 'running' limit 1
	} or { []LinkScan{} }
	if running.len > 0 {
		return running[0].id
	}
	row := LinkScan{
		requested: now
		source:    source
		state:     'requested'
	}
	sql s.db {
		insert row into LinkScan
	}!
	made := sql s.db {
		select from LinkScan where state == 'requested' limit 1
	} or { []LinkScan{} }
	return if made.len > 0 { made[0].id } else { 0 }
}

pub fn (mut s SqliteStore) pending_link_scan() ?LinkScan {
	rows := sql s.db {
		select from LinkScan where state == 'requested' limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) set_link_scan_running(id int, now i64) ! {
	sql s.db {
		update LinkScan set state = 'running', started = now where id == id
	}!
}

pub fn (mut s SqliteStore) finish_link_scan(id int, now i64, sum Summary) ! {
	repeaters, reached, probes, replies := sum.repeaters, sum.reached, sum.probes, sum.replies
	sql s.db {
		update LinkScan set state = 'done', finished = now, repeaters = repeaters, reached = reached,
		probes = probes, replies = replies where id == id
	}!
}

pub fn (mut s SqliteStore) recent_link_scans(limit int) []LinkScan {
	return sql s.db {
		select from LinkScan order by id desc limit limit
	} or { []LinkScan{} }
}

pub fn (mut s SqliteStore) add_route_test(route string, hash_size int, now i64) ! {
	row := RouteTest{
		requested: now
		route:     route
		hash_size: hash_size
		state:     'requested'
	}
	sql s.db {
		insert row into RouteTest
	}!
}

pub fn (mut s SqliteStore) pending_route_test() ?RouteTest {
	rows := sql s.db {
		select from RouteTest where state == 'requested' order by id limit 1
	} or { []RouteTest{} }
	return if rows.len > 0 { rows[0] } else { none }
}

pub fn (mut s SqliteStore) finish_route_test(id int, now i64, reply TraceReply, ok bool) ! {
	state := 'done'
	good := if ok { 1 } else { 0 }
	rtt := if ok { reply.rtt_ms } else { 0 }
	snrs := reply.snrs.map('${it:.2f}').join(',')
	final := reply.final_snr
	sql s.db {
		update RouteTest set state = state, finished = now, ok = good, rtt_ms = rtt, snrs = snrs,
		final_snr = final where id == id
	}!
}

pub fn (mut s SqliteStore) list_route_tests(limit int) []RouteTest {
	return sql s.db {
		select from RouteTest order by id desc limit limit
	} or { []RouteTest{} }
}

// close_stale_link_scans marks a scan that was running when the daemon stopped as done, so a restart does not leave it running for ever.
pub fn (mut s SqliteStore) close_stale_link_scans(now i64) {
	sql s.db {
		update LinkScan set state = 'done', finished = now where state == 'running'
	} or {}
}
