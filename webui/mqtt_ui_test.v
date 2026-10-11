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
	return db
}

fn test_contract_columns_present() {
	// guards the helper above against drifting from the shared contract
	mut db := fresh_db()
	for t, cols in {
		'mqtt_settings': mqttcfg.settings_columns
		'mqtt_brokers':  mqttcfg.broker_columns
		'mqtt_status':   mqttcfg.status_columns
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
