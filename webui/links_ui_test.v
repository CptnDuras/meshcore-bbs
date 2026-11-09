module main

import db.sqlite

// The tables as the daemon makes them (bbs/models.v); bbs/store_links_test.v checks these column lists against the real ones.
const ddl = [
	'CREATE TABLE node_names (id INTEGER PRIMARY KEY, pubkey_prefix TEXT, name TEXT, contact_type INTEGER, last_advert INTEGER, updated INTEGER)',
	'CREATE TABLE link_edges (id INTEGER PRIMARY KEY, a_id TEXT, b_id TEXT, tries INTEGER, oks INTEGER, lat_n INTEGER, lat_sum_ms INTEGER, lat_min_ms INTEGER, lat_max_ms INTEGER, lat_last_ms INTEGER, depth INTEGER, last_ts INTEGER, last_ok_ts INTEGER)',
	'CREATE TABLE link_hops (id INTEGER PRIMARY KEY, from_id TEXT, to_id TEXT, n INTEGER, snr_sum REAL, snr_min REAL, snr_max REAL, snr_last REAL, last_ts INTEGER)',
	'CREATE TABLE link_scans (id INTEGER PRIMARY KEY, requested INTEGER, started INTEGER, finished INTEGER, source TEXT, state TEXT, repeaters INTEGER, reached INTEGER, probes INTEGER, replies INTEGER)',
]

fn new_db() sqlite.DB {
	mut db := sqlite.connect(':memory:') or { panic(err) }
	for q in ddl {
		db.exec(q) or { panic(err) }
	}
	return db
}

fn test_links_query_names_both_ends_and_averages() {
	mut db := new_db()
	db.exec("INSERT INTO node_names (pubkey_prefix,name) VALUES ('aa1111111111','Alpha')") or { panic(err) }
	db.exec("INSERT INTO link_edges (a_id,b_id,tries,oks,lat_n,lat_sum_ms,lat_min_ms,lat_max_ms,depth,last_ok_ts) VALUES ('aa1111111111','self',3,2,2,300,100,200,1,1794787200)") or {
		panic(err)
	}
	db.exec("INSERT INTO link_hops (from_id,to_id,n,snr_sum) VALUES ('aa1111111111','self',2,19.0),('self','aa1111111111',1,-4.5)") or {
		panic(err)
	}
	rows := db.exec(links_sql) or { panic(err) }
	assert rows.len == 1
	v := rows[0].vals
	assert v[0] == 'Alpha'
	assert v[1] == 'BBS' // this node's own end
	assert v[2] == '9.5' // aa -> self averaged over two traces
	assert v[3] == '-4.5'
	assert v[4] == '150 (100-200)'
	assert v[5] == '1'
	assert v[6] == '2/3'
	assert v[7] != 'never'
}

fn test_links_query_shows_an_unanswered_link_last_without_numbers() {
	mut db := new_db()
	db.exec("INSERT INTO link_edges (a_id,b_id,tries,oks,lat_n,lat_sum_ms,depth,last_ok_ts) VALUES ('bb2222222222','cc3333333333',2,0,0,0,0,0)") or {
		panic(err)
	}
	db.exec("INSERT INTO link_edges (a_id,b_id,tries,oks,lat_n,lat_sum_ms,lat_min_ms,lat_max_ms,depth,last_ok_ts) VALUES ('aa1111111111','dd4444444444',1,1,1,80,80,80,2,5)") or {
		panic(err)
	}
	rows := db.exec(links_sql) or { panic(err) }
	assert rows.len == 2
	assert rows[0].vals[0] == 'aa1111' // an answered link comes first; no name known, so the first bytes of the key
	assert rows[1].vals[2] == '-' && rows[1].vals[4] == '-' && rows[1].vals[5] == '-'
	assert rows[1].vals[6] == '0/2' && rows[1].vals[7] == 'never'
}

fn test_scan_request_queues_once() {
	mut db := new_db()
	db.exec(scan_request_sql(100)) or { panic(err) }
	db.exec(scan_request_sql(200)) or { panic(err) } // a second click while one waits does nothing
	assert db.exec('SELECT COUNT(*) FROM link_scans') or { panic(err) }[0].vals[0] == '1'
	r := db.exec('SELECT requested, source, state FROM link_scans') or { panic(err) }
	assert r[0].vals == ['100', 'sysop', 'requested']
	db.exec("UPDATE link_scans SET state='done'") or { panic(err) }
	db.exec(scan_request_sql(300)) or { panic(err) } // finished: a new one may be asked for
	assert db.exec('SELECT COUNT(*) FROM link_scans') or { panic(err) }[0].vals[0] == '2'
}

fn test_scans_query_runs() {
	mut db := new_db()
	db.exec("INSERT INTO link_scans (requested,started,finished,source,state,repeaters,reached,probes,replies) VALUES (10,20,80,'schedule','done',9,7,30,18)") or {
		panic(err)
	}
	rows := db.exec(scans_sql) or { panic(err) }
	assert rows.len == 1
	assert rows[0].vals[1] == 'schedule' && rows[0].vals[2] == 'done'
	assert rows[0].vals[7] == '60 s'
}

fn test_page_connections_wait_for_a_locked_database() {
	app := App{
		db_path: ':memory:'
	}
	mut db := app.db() or { panic(err) }
	assert (db.exec('PRAGMA busy_timeout') or { panic(err) })[0].vals[0] == '5000'
}
