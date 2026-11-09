module main

fn names(id string) string {
	return match id {
		'aa' { 'Alpha' }
		'bb' { 'Bravo' }
		'cc' { 'Charlie' }
		link_self { 'BBS' }
		else { id }
	}
}

fn edge(a string, b string, oks int, tries int, lat_n int, lat_sum i64) LinkEdge {
	return LinkEdge{
		a_id:       a
		b_id:       b
		oks:        oks
		tries:      tries
		lat_n:      lat_n
		lat_sum_ms: lat_sum
		depth:      1
		last_ok_ts: 100
	}
}

fn hop(f string, t string, n int, sum f64) LinkHop {
	return LinkHop{
		from_id: f
		to_id:   t
		n:       n
		snr_sum: sum
	}
}

fn test_link_rows_average_each_direction_and_skip_unanswered_links() {
	rows := link_rows([edge('aa', 'bb', 2, 3, 2, 400), edge('bb', 'cc', 0, 2, 0, 0)],
		[hop('aa', 'bb', 2, 10.0), hop('bb', 'aa', 4, -8.0)], names)
	assert rows.len == 1 // the unanswered link is not a measured link
	r := rows[0]
	assert r.a == 'Alpha' && r.b == 'Bravo'
	assert r.snr_ab == 5.0 && r.has_ab
	assert r.snr_ba == -2.0 && r.has_ba
	assert r.lat_ms == 200
	assert r.weakest() == -2.0
}

fn test_link_row_with_one_direction_only() {
	r := link_rows([edge('aa', 'bb', 1, 1, 1, 90)], [hop('aa', 'bb', 1, 7.5)], names)[0]
	assert r.has_ab && !r.has_ba
	assert r.weakest() == 7.5
}

fn test_summary_with_nothing() {
	assert links_summary([]LinkRow{}, 0, none, 1000) == 'No links measured yet.'
}

fn test_summary_lists_weakest_strongest_slowest() {
	edges := [edge('aa', link_self, 1, 1, 1, 50), edge('aa', 'bb', 1, 1, 1, 400),
		edge('bb', 'cc', 1, 2, 1, 120)]
	hops := [hop(link_self, 'aa', 1, 12.0), hop('aa', link_self, 1, 11.0), hop('aa', 'bb', 1, 2.0),
		hop('bb', 'aa', 1, 3.0), hop('bb', 'cc', 1, -6.0), hop('cc', 'bb', 1, -5.0)]
	out := links_summary(link_rows(edges, hops, names), 2, none, 1000)
	assert out.starts_with('Links: 3 measured, 2 never answered')
	assert out.contains('Weakest:\n Bravo<>Charlie -6.0/-5.0dB 120ms')
	assert out.contains('Strongest:\n Alpha<>BBS 11.0/12.0dB 50ms')
	assert out.contains('Slowest:\n Alpha<>Bravo')
}

fn test_summary_last_scan_line() {
	scan := LinkScan{
		state:     'done'
		finished:  1000
		repeaters: 11
		reached:   9
		probes:    31
		replies:   20
	}
	out := links_summary([]LinkRow{}, 0, scan, 1000 + 2 * 3600)
	assert out.ends_with('Last scan 2h ago: reached 9/11, 20/31 probes answered')
	busy := LinkScan{
		state: 'running'
	}
	assert links_summary([]LinkRow{}, 0, busy, 5).ends_with('A scan is running.')
}

fn test_ago_text() {
	assert ago_text(10) == '10s'
	assert ago_text(600) == '10m'
	assert ago_text(3 * 3600) == '3h'
	assert ago_text(3 * 86400) == '3d'
}
