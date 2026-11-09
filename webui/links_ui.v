module main

// Repeater links: what the daemon's link scan has measured between repeaters, and a button to ask for a scan now. Like the other pages this only
// reads and writes the shared database: pressing the button queues a request (link_scans, state requested) that the daemon picks up in its loop.

import veb
import time

// One row per link, strongest evidence first. A link's two ends are named from node_names (or the first bytes of the key, or BBS for this node);
// the SNR is the average heard in each direction, and the delay the average one way time over every answered trace.
const links_sql = "SELECT
	COALESCE(na.name, CASE WHEN e.a_id='self' THEN 'BBS' ELSE substr(e.a_id,1,6) END),
	COALESCE(nb.name, CASE WHEN e.b_id='self' THEN 'BBS' ELSE substr(e.b_id,1,6) END),
	CASE WHEN ab.n > 0 THEN printf('%.1f', ab.snr_sum / ab.n) ELSE '-' END,
	CASE WHEN ba.n > 0 THEN printf('%.1f', ba.snr_sum / ba.n) ELSE '-' END,
	CASE WHEN e.lat_n > 0 THEN (e.lat_sum_ms / e.lat_n) || ' (' || e.lat_min_ms || '-' || e.lat_max_ms || ')' ELSE '-' END,
	CASE WHEN e.depth > 0 THEN e.depth ELSE '-' END,
	e.oks || '/' || e.tries,
	CASE WHEN e.last_ok_ts > 0 THEN datetime(e.last_ok_ts, 'unixepoch', 'localtime') ELSE 'never' END
FROM link_edges e
LEFT JOIN node_names na ON na.pubkey_prefix = e.a_id
LEFT JOIN node_names nb ON nb.pubkey_prefix = e.b_id
LEFT JOIN link_hops ab ON ab.from_id = e.a_id AND ab.to_id = e.b_id
LEFT JOIN link_hops ba ON ba.from_id = e.b_id AND ba.to_id = e.a_id
ORDER BY (e.oks = 0), e.depth, 1, 2"

const scans_sql = "SELECT
	CASE WHEN started > 0 THEN datetime(started, 'unixepoch', 'localtime') ELSE datetime(requested, 'unixepoch', 'localtime') END,
	source, state, repeaters, reached, probes, replies,
	CASE WHEN finished > 0 AND started > 0 THEN (finished - started) || ' s' ELSE '-' END
FROM link_scans ORDER BY id DESC LIMIT 12"

// scan_request_sql queues a scan unless one is already waiting or running, so a second click does nothing.
fn scan_request_sql(now i64) string {
	return "INSERT INTO link_scans (requested,started,finished,source,state,repeaters,reached,probes,replies)
		SELECT ${now},0,0,'sysop','requested',0,0,0,0
		WHERE NOT EXISTS (SELECT 1 FROM link_scans WHERE state IN ('requested','running'))"
}

@['/links']
pub fn (app &App) links(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	links := query_table(mut db, ['Node A', 'Node B', 'SNR A to B (dB)', 'SNR B to A (dB)',
		'Delay ms one way (min-max)', 'Hops from BBS', 'Answered', 'Last answered'], links_sql)
	scans := query_table(mut db, ['Time', 'Started by', 'State', 'Repeaters', 'Reached', 'Probes',
		'Answered', 'Took'], scans_sql)
	busy := scalar(mut db, "SELECT COUNT(*) FROM link_scans WHERE state IN ('requested','running')") != '0'
	return $veb.html('templates/links.html')
}

@['/links/scan'; post]
pub fn (app &App) links_scan(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/links', typ: .found) }
	defer { db.close() or {} }
	db.exec(scan_request_sql(time.now().unix())) or {}
	return ctx.redirect('/links', typ: .found)
}
