module main

// Weather-alert page (/alerts): shows that the NWS subscription is alive, who
// alerts currently go to, and a button that sends a test alert. The page only
// reads/writes the shared DB; the daemon (sole owner of the radio) picks up the
// test request and queues the messages. See bbs/alerts.v.

import db.sqlite
import net.urllib
import time
import veb

const alert_default_node = 'd2267935c4d5' // XeroKuhl-Portable3

struct AlertReq {
	when string
	done bool
	note string
}

struct AlertsPage {
	available   bool
	public      bool
	test_node   string
	node_name   string
	last_poll   string
	poll_ok     bool
	polled      bool
	poll_age    string
	last_active string
	pending     int
	recent      []AlertReq
}

fn alert_setting(mut db sqlite.DB, key string) string {
	rows := db.exec_param('SELECT val FROM alert_settings WHERE key=?', key) or { return '' }
	if rows.len == 0 || rows[0].vals.len == 0 {
		return ''
	}
	return rows[0].vals[0]
}

fn alert_put_setting(mut db sqlite.DB, key string, val string) {
	rows := db.exec_param('SELECT COUNT(*) FROM alert_settings WHERE key=?', key) or { return }
	if rows.len > 0 && rows[0].vals[0].int() > 0 {
		db.exec_param2('UPDATE alert_settings SET val=? WHERE key=?', val, key) or {}
	} else {
		db.exec_param2('INSERT INTO alert_settings (key, val) VALUES (?, ?)', key, val) or {}
	}
}

fn alerts_load(mut db sqlite.DB) AlertsPage {
	db.exec('SELECT 1 FROM alert_settings LIMIT 1') or { return AlertsPage{} }
	db.exec('SELECT 1 FROM alert_requests LIMIT 1') or { return AlertsPage{} }
	node := alert_setting(mut db, 'alert_test_node')
	test_node := if node.len > 0 { node } else { alert_default_node }
	names := db.exec_param('SELECT name FROM node_names WHERE pubkey_prefix=?', test_node) or {
		[]sqlite.Row{}
	}
	lp := alert_setting(mut db, 'last_poll').i64()
	age := if lp > 0 {
		secs := time.now().unix() - lp
		if secs < 120 { '${secs}s ago' } else { '${secs / 60} min ago' }
	} else {
		''
	}
	mut recent := []AlertReq{}
	for r in db.exec('SELECT requested, done, note FROM alert_requests ORDER BY id DESC LIMIT 8') or {
		[]sqlite.Row{}
	} {
		recent << AlertReq{
			when: fmt_ts(r.vals[0])
			done: r.vals[1] == '1'
			note: r.vals[2]
		}
	}
	return AlertsPage{
		available:   true
		public:      alert_setting(mut db, 'alert_scope') == 'public'
		test_node:   test_node
		node_name:   if names.len > 0 { names[0].vals[0] } else { '' }
		last_poll:   fmt_ts(alert_setting(mut db, 'last_poll'))
		polled:      lp > 0
		poll_ok:     alert_setting(mut db, 'last_poll_ok') == '1'
		poll_age:    age
		last_active: alert_setting(mut db, 'last_active')
		pending:     scalar(mut db, 'SELECT COUNT(*) FROM alert_requests WHERE done=0').int()
		recent:      recent
	}
}

fn alerts_back(mut ctx Context, msg string) veb.Result {
	return ctx.redirect('/alerts?msg=' + urllib.query_escape(msg), typ: .found)
}

@['/alerts']
pub fn (app &App) alerts(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	page := alerts_load(mut db)
	msg := ctx.query['msg'] or { '' }
	return $veb.html('templates/alerts.html')
}

@['/alerts/test'; post]
pub fn (app &App) alerts_test(mut ctx Context) veb.Result {
	mut db := app.db() or { return alerts_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	db.exec('SELECT 1 FROM alert_requests LIMIT 1') or {
		return alerts_back(mut ctx, 'Restart the meshbbs daemon once so it creates the alert tables.')
	}
	if scalar(mut db, 'SELECT COUNT(*) FROM alert_requests WHERE done=0').int() > 0 {
		return alerts_back(mut ctx, 'A test is already waiting for the daemon.')
	}
	db.exec_param('INSERT INTO alert_requests (requested, done, note) VALUES (?, 0, \'\')',
		time.now().unix().str()) or {}
	return alerts_back(mut ctx, 'Test alert requested. The daemon sends it within a few seconds.')
}

@['/alerts/scope'; post]
pub fn (app &App) alerts_scope(mut ctx Context) veb.Result {
	mut db := app.db() or { return alerts_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	want := ctx.form['scope'] or { '' }
	if want == 'public' {
		if (ctx.form['confirm'] or { '' }) != 'yes' {
			return alerts_back(mut ctx, 'Tick the confirmation box to go public.')
		}
		alert_put_setting(mut db, 'alert_scope', 'public')
		return alerts_back(mut ctx, 'Alerts are now PUBLIC: real alerts go to the channel and warnings are DMed to everyone.')
	}
	alert_put_setting(mut db, 'alert_scope', 'restricted')
	return alerts_back(mut ctx, 'Alerts are restricted to the test node only.')
}
