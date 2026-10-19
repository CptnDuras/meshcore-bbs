module main

import db.sqlite
import mqttcfg
import os
import time

// Builds the same tables the daemon's ORM creates (column lists come from the
// shared contract, which bbs/mqtt_store_test.v verifies against the real ORM).
fn fresh_db() sqlite.DB {
	path := os.join_path(os.temp_dir(), 'webui_mqtt_${os.getpid()}_${time.now().unix_nano()}.db')
	db := sqlite.connect(path) or { panic(err) }
	db.exec('CREATE TABLE mqtt_settings (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT NOT NULL UNIQUE, val TEXT NOT NULL)') or {
		panic(err)
	}
	db.exec('CREATE TABLE mqtt_brokers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, enabled INTEGER NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL, transport TEXT NOT NULL, path TEXT NOT NULL, auth TEXT NOT NULL, username TEXT NOT NULL, password TEXT NOT NULL, audience TEXT NOT NULL, created INTEGER NOT NULL)') or {
		panic(err)
	}
	db.exec('CREATE TABLE mqtt_status (id INTEGER PRIMARY KEY AUTOINCREMENT, broker_id INTEGER NOT NULL UNIQUE, state TEXT NOT NULL, last_error TEXT NOT NULL, published INTEGER NOT NULL, updated INTEGER NOT NULL)') or {
		panic(err)
	}
	db.exec('CREATE TABLE mqtt_log (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, kind TEXT NOT NULL, broker TEXT NOT NULL, summary TEXT NOT NULL, detail TEXT NOT NULL)') or {
		panic(err)
	}
	return db
}

fn test_contract_columns_present() {
	// guards the helper above against drifting from the shared contract
	mut db := fresh_db()
	for t, cols in {
		'mqtt_settings': mqttcfg.settings_columns
		'mqtt_brokers':  mqttcfg.broker_columns
		'mqtt_status':   mqttcfg.status_columns
		'mqtt_log':      mqttcfg.log_columns
	} {
		rows := db.exec('PRAGMA table_info(${t})') or { panic(err) }
		mut got := []string{}
		for r in rows {
			got << r.vals[1]
		}
		assert got == cols, t
	}
}

fn test_load_defaults_off() {
	mut db := fresh_db()
	p := mqtt_load(mut db)
	assert p.available
	assert !p.enabled
	assert p.brokers.len == 0
	assert 'meshmapper' in p.presets
}

fn test_load_when_tables_missing() {
	path := os.join_path(os.temp_dir(), 'webui_mqtt_empty_${os.getpid()}.db')
	mut db := sqlite.connect(path) or { panic(err) }
	p := mqtt_load(mut db)
	assert !p.available
}

fn test_save_settings_validates_iata_and_bumps_rev() {
	mut db := fresh_db()
	assert mqtt_save_settings(mut db, true, 'xx').contains('IATA')
	assert !mqtt_load(mut db).enabled // nothing changed on error
	assert mqtt_save_settings(mut db, true, ' byg ') == ''
	p := mqtt_load(mut db)
	assert p.enabled
	assert p.iata == 'BYG'
	assert p.rev.int() > 0
	r0 := p.rev.int()
	// disabling with a blank code is fine
	assert mqtt_save_settings(mut db, false, '') == ''
	p2 := mqtt_load(mut db)
	assert !p2.enabled
	assert p2.rev.int() > r0
}

fn test_add_broker_from_preset_and_custom() {
	mut db := fresh_db()
	assert mqtt_add_broker(mut db, {
		'preset': 'meshmapper'
	}) == ''
	assert mqtt_add_broker(mut db, {
		'preset':    ''
		'name':      'home'
		'host':      '10.0.0.5'
		'port':      '1883'
		'transport': 'tcp'
		'auth':      'password'
		'username':  'u'
		'password':  'secret'
	}) == ''
	p := mqtt_load(mut db)
	assert p.brokers.len == 2
	assert p.brokers[0].host == 'mqtt.meshmapper.net'
	assert p.brokers[0].auth == 'token'
	assert p.brokers[1].port == 1883
	assert p.brokers[1].has_password
	// the password itself is never exposed to the page
	assert !p.brokers[1].str().contains('secret')
	// invalid input is rejected and nothing is added
	assert mqtt_add_broker(mut db, {
		'preset': ''
		'name':   'bad'
		'host':   'x y'
		'port':   '1'
	}).contains('host')
	assert mqtt_load(mut db).brokers.len == 2
}

fn test_update_keeps_password_when_blank() {
	mut db := fresh_db()
	mqtt_add_broker(mut db, {
		'preset':   ''
		'name':     'home'
		'host':     '10.0.0.5'
		'port':     '1883'
		'auth':     'password'
		'username': 'u'
		'password': 'secret'
	})
	id := mqtt_load(mut db).brokers[0].id
	err := mqtt_update_broker(mut db, id, {
		'name':      'home2'
		'host':      '10.0.0.6'
		'port':      '8883'
		'transport': 'tls'
		'auth':      'password'
		'username':  'u2'
		'password':  ''
	})
	assert err == ''
	rows := db.exec('SELECT name, host, port, transport, username, password FROM mqtt_brokers WHERE id=${id}') or {
		panic(err)
	}
	assert rows[0].vals == ['home2', '10.0.0.6', '8883', 'tls', 'u2', 'secret']
	// a non-blank password replaces it
	mqtt_update_broker(mut db, id, {
		'name':      'home2'
		'host':      '10.0.0.6'
		'port':      '8883'
		'transport': 'tls'
		'auth':      'password'
		'username':  'u2'
		'password':  'newpw'
	})
	r2 := db.exec('SELECT password FROM mqtt_brokers WHERE id=${id}') or { panic(err) }
	assert r2[0].vals[0] == 'newpw'
	// invalid update is rejected, row unchanged
	assert mqtt_update_broker(mut db, id, {
		'name': 'x'
		'host': ''
		'port': '1'
	}).contains('host')
	r3 := db.exec('SELECT host FROM mqtt_brokers WHERE id=${id}') or { panic(err) }
	assert r3[0].vals[0] == '10.0.0.6'
}

fn test_toggle_and_delete_bump_rev_and_clean_status() {
	mut db := fresh_db()
	mqtt_add_broker(mut db, {
		'preset': 'local'
	})
	id := mqtt_load(mut db).brokers[0].id
	db.exec("INSERT INTO mqtt_status (broker_id,state,last_error,published,updated) VALUES (${id},'connected','',5,1)") or {
		panic(err)
	}
	p := mqtt_load(mut db)
	assert p.brokers[0].state == 'connected'
	assert p.brokers[0].published == 5
	r0 := p.rev.int()
	mqtt_toggle_broker(mut db, id, false)
	p2 := mqtt_load(mut db)
	assert !p2.brokers[0].enabled
	assert p2.rev.int() > r0
	mqtt_delete_broker(mut db, id)
	p3 := mqtt_load(mut db)
	assert p3.brokers.len == 0
	rows := db.exec('SELECT COUNT(*) FROM mqtt_status') or { panic(err) }
	assert rows[0].vals[0] == '0'
}

fn test_values_with_quotes_are_stored_literally() {
	mut db := fresh_db()
	assert mqtt_add_broker(mut db, {
		'preset':   ''
		'name':     "o'brien"
		'host':     'h.example.org'
		'port':     '1883'
		'auth':     'password'
		'username': "u'; DROP TABLE mqtt_brokers; --"
		'password': "p'w"
	}) == ''
	rows := db.exec('SELECT name, username, password FROM mqtt_brokers') or { panic(err) }
	assert rows[0].vals == ["o'brien", "u'; DROP TABLE mqtt_brokers; --", "p'w"]
}

fn test_template_helpers() {
	assert checked_attr(true) == 'checked'
	assert checked_attr(false) == ''
	assert sel_attr('tcp', 'tcp') == 'selected'
	assert sel_attr('tcp', 'wss') == ''
	assert pw_hint(true) == '(unchanged)'
	assert pw_hint(false) == ''
}

fn test_h_escapes_html() {
	assert h('<script>alert(1)</script>') == '&lt;script&gt;alert(1)&lt;/script&gt;'
	assert h('a"b\'c&d') == 'a&quot;b&#39;c&amp;d'
	assert h('plain') == 'plain'
}

fn add_log(mut db sqlite.DB, ts int, kind string, broker string, summary string, detail string) {
	db.exec_param_many('INSERT INTO mqtt_log (ts, kind, broker, summary, detail) VALUES (?,?,?,?,?)', [
		ts.str(),
		kind,
		broker,
		summary,
		detail,
	]) or {
		panic(err)
	}
}

fn test_log_page_filters_and_orders() {
	mut db := fresh_db()
	add_log(mut db, 1000, 'daemon', '', 'publisher started', '')
	add_log(mut db, 1001, 'broker', 'letsmesh-us', 'connected', '')
	add_log(mut db, 1002, 'packet', '', 'ADVERT flood 80 B  SNR 4  RSSI -90  AAAA1111', '{"hash":"AAAA1111"}')
	add_log(mut db, 1003, 'packet', '', 'GRP_TXT flood 60 B  SNR -2  RSSI -101  BBBB2222', '{"hash":"BBBB2222"}')
	all := mqtt_log_load(mut db, 'all', '', 200)
	assert all.available
	assert all.rows.map(it.summary.split(' ')[0]) == ['GRP_TXT', 'ADVERT', 'connected', 'publisher']
	assert all.packets == 2
	assert all.events == 2
	assert mqtt_log_load(mut db, 'packet', '', 200).rows.len == 2
	other := mqtt_log_load(mut db, 'other', '', 200)
	assert other.rows.map(it.kind) == ['broker', 'daemon']
	// text filter is case-insensitive and also matches the broker name
	assert mqtt_log_load(mut db, 'all', 'bbbb', 200).rows.len == 1
	assert mqtt_log_load(mut db, 'all', 'LETSMESH', 200).rows.len == 1
	// limit applies to the newest rows
	lim := mqtt_log_load(mut db, 'all', '', 100)
	assert lim.limit == 100
	// '%' and quotes in the filter are plain text, not SQL
	assert mqtt_log_load(mut db, 'all', "%' OR '1'='1", 200).rows.len == 0
}

fn test_log_page_without_table_is_unavailable() {
	path := os.join_path(os.temp_dir(), 'webui_nolog_${os.getpid()}_${time.now().unix_nano()}.db')
	mut db := sqlite.connect(path) or { panic(err) }
	p := mqtt_log_load(mut db, 'all', '', 200)
	assert !p.available
	assert p.rows.len == 0
}

fn test_log_helpers() {
	assert mqtt_log_limit('') == 200
	assert mqtt_log_limit('500') == 500
	assert mqtt_log_limit('99999') == 200
	assert mqtt_log_kind('packet') == 'packet'
	assert mqtt_log_kind('x') == 'all'
	txt := mqtt_log_text([MqttLogView{
		time:    't'
		kind:    'packet'
		summary: 's'
		detail:  'd'
	}, MqttLogView{
		time:    't2'
		kind:    'broker'
		broker:  'b'
		summary: 'connected'
	}])
	assert txt == 't  packet  s\n    d\nt2  broker [b]  connected\n'
}
