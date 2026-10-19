module main

// Weather-alert page (/alerts): shows that the NWS subscription is alive, who
// alerts currently go to, and a button that sends a test alert. The page only
// reads/writes the shared DB; the daemon (sole owner of the radio) picks up the
// test request and queues the messages. See bbs/alerts.v.

import db.sqlite
import net.urllib
import time
import veb

struct AlertReq {
	when string
	done bool
	note string
}

struct NodeOpt {
	prefix string
	label  string
	sel    string
}

// valid_hex_prefix returns s lower-cased if it is a 4..64 char hex string, else ''.
fn valid_hex_prefix(s string) string {
	p := s.trim_space().to_lower()
	if p.len < 4 || p.len > 64 {
		return ''
	}
	for c in p {
		if !((c >= `0` && c <= `9`) || (c >= `a` && c <= `f`)) {
			return ''
		}
	}
	return p
}

struct AlertsPage {
	available   bool
	public      bool
	test_node   string
	node_name   string
	nodes       []NodeOpt
	chan_cmds   bool
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
	test_node := valid_hex_prefix(alert_setting(mut db, 'alert_test_node'))
	names := db.exec_param('SELECT name FROM node_names WHERE pubkey_prefix=?', test_node) or {
		[]sqlite.Row{}
	}
	mut nodes := []NodeOpt{}
	for r in db.exec("SELECT pubkey_prefix, name FROM node_names WHERE name<>'' ORDER BY name LIMIT 500") or {
		[]sqlite.Row{}
	} {
		nodes << NodeOpt{
			prefix: r.vals[0]
			label:  '${r.vals[1]} (${r.vals[0]})'
			sel:    if r.vals[0] == test_node { 'selected' } else { '' }
		}
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
		nodes:       nodes
		chan_cmds:   alert_setting(mut db, 'chan_commands') != '0'
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

// alerts renders the weather-alert page.
@['/alerts']
pub fn (app &App) alerts(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	page := alerts_load(mut db)
	msg := ctx.query['msg'] or { '' }
	return $veb.html('templates/alerts.html')
}

// alerts_test queues a test alert for the daemon to send to the chosen target.
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
	mut target := ctx.form['target'] or { 'scope' }
	if target == 'custom' {
		target = 'node:' + valid_hex_prefix(ctx.form['custom'] or { '' })
	}
	if target != 'scope' && target != 'chan' {
		if !target.starts_with('node:') || valid_hex_prefix(target['node:'.len..]).len == 0 {
			return alerts_back(mut ctx, 'Pick a target for the test (or enter a valid node id).')
		}
	}
	db.exec_param2("INSERT INTO alert_requests (requested, done, note, target) VALUES (?, 0, '', ?)",
		time.now().unix().str(), target) or {
		return alerts_back(mut ctx, 'Could not queue the test: ' + err.msg())
	}
	return alerts_back(mut ctx, 'Test alert requested. The daemon sends it within a few seconds.')
}

// alerts_scope switches real alerts between restricted and public.
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

// alerts_node sets the node that restricted-mode alerts go to.
@['/alerts/node'; post]
pub fn (app &App) alerts_node(mut ctx Context) veb.Result {
	mut db := app.db() or { return alerts_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	raw := ctx.form['node'] or { '' }
	node := valid_hex_prefix(raw)
	if raw.trim_space().len > 0 && node.len == 0 {
		return alerts_back(mut ctx, 'That is not a valid node id.')
	}
	alert_put_setting(mut db, 'alert_test_node', node)
	return alerts_back(mut ctx, if node.len > 0 {
		'Restricted alerts now go only to ' + node + '.'
	} else {
		'No restricted node set: while restricted, alerts are not sent to anyone.'
	})
}

// alerts_chancmds turns the public-channel slash commands on or off.
@['/alerts/chancmds'; post]
pub fn (app &App) alerts_chancmds(mut ctx Context) veb.Result {
	mut db := app.db() or { return alerts_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	on := (ctx.form['enabled'] or { '' }) == '1'
	alert_put_setting(mut db, 'chan_commands', if on { '1' } else { '0' })
	return alerts_back(mut ctx, if on {
		'Public channel commands are ON.'
	} else {
		'Public channel commands are OFF.'
	})
}
