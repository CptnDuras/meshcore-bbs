module main

// meshbbs web UI on veb (templated).
//
// Architecture (unchanged from the design): a SEPARATE process from the radio
// daemon. It only reads/writes the shared SQLite DB — it NEVER touches the
// serial port. Scheduling a message inserts into scheduled_messages; an
// on-demand broadcast inserts into outbound_messages; the daemon evaluates and
// transmits on its own loop.
//
// Plain HTTP bound to the Tailscale interface (+ localhost via the tailnet).
// veb templates ($veb.html) render the pages from ./templates/*.html.
//
// Usage: meshbbs-webui [db_path] [host] [port]
//   db_path default meshbbs.db, host default 100.118.159.79, port default 8080

import veb
import db.sqlite
import net.urllib
import os
import time

const default_db = 'meshbbs.db'
const default_host = '100.118.159.79'
const default_port = 8080

// App is the veb global app (shared across requests).
pub struct App {
pub mut:
	db_path string
}

// Context is per-request state.
pub struct Context {
	veb.Context
}

// --- small view models used by templates ---

struct Stat {
	label string
	value string
	link  string
}

struct Row {
	cells []string
}

struct Table {
	headers []string
	rows    []Row
}

struct Sched {
	id       string
	target   string
	text     string
	source   string
	kind     string
	whenv    string
	enabled  bool
}

struct UserRow {
	handle    string
	level     string
	level_num int
	banned    bool
	last_seen string
}

// --- routes ---

@['/']
pub fn (app &App) index(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	stats := [
		Stat{'Users', scalar(mut db, 'SELECT COUNT(*) FROM users'), '/users'},
		Stat{'Messages', scalar(mut db, 'SELECT COUNT(*) FROM bbs_messages'), '/messages'},
		Stat{'Known nodes', scalar(mut db, 'SELECT COUNT(*) FROM node_names'), '/nodes'},
		Stat{'Interactions', scalar(mut db, 'SELECT COUNT(*) FROM interactions'), '/interactions'},
		Stat{'Mesh pkts seen', scalar(mut db, 'SELECT COUNT(*) FROM mesh_traffic'), '/traffic'},
		Stat{'Schedules', scalar(mut db, 'SELECT COUNT(*) FROM scheduled_messages'), '/schedules'},
		Stat{'Outbound pending', scalar(mut db, 'SELECT COUNT(*) FROM outbound_messages WHERE sent=0'), '/schedules'},
	]
	return $veb.html('templates/dashboard.html')
}

@['/nodes']
pub fn (app &App) nodes(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	title := 'Known nodes'
	table := query_table(mut db, ['Node', 'Name', 'Type'], 'SELECT pubkey_prefix, name, contact_type FROM node_names ORDER BY name')
	return $veb.html('templates/table.html')
}

@['/interactions']
pub fn (app &App) interactions(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	title := 'Interactions (latest 200)'
	table := query_table(mut db, ['Time', 'Node', 'Name', 'Handle', 'Cmd', 'Text'],
		"SELECT i.ts, i.pubkey_prefix, COALESCE(n.name,''), i.handle, i.command, i.text FROM interactions i LEFT JOIN node_names n ON n.pubkey_prefix=i.pubkey_prefix ORDER BY i.id DESC LIMIT 200")
	return $veb.html('templates/table.html')
}

@['/messages']
pub fn (app &App) messages(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	title := 'Board messages'
	table := query_table(mut db, ['Time', 'Board', 'Author', 'Subject', 'Body'],
		"SELECT m.posted, COALESCE(b.name,'?'), m.author, m.subject, m.body FROM bbs_messages m LEFT JOIN boards b ON b.id=m.board_id ORDER BY m.id DESC LIMIT 200")
	return $veb.html('templates/table.html')
}

@['/macros']
pub fn (app &App) macros(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	macros := query_table(mut db, ['Owner', 'Command', 'Reply text'],
		'SELECT owner, name, text FROM user_macros ORDER BY owner, name')
	prefs := query_table(mut db, ['Owner', 'Key', 'Value'],
		'SELECT owner, key, val FROM user_prefs ORDER BY owner, key')
	return $veb.html('templates/macros.html')
}

@['/traffic']
pub fn (app &App) traffic(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	title := 'Mesh traffic (latest 200)'
	table := query_table(mut db, ['Time', 'Kind', 'Node', 'Name', 'SNR', 'Hops'],
		"SELECT t.ts, t.kind, t.pubkey_prefix, COALESCE(n.name,''), t.snr, t.path_len FROM mesh_traffic t LEFT JOIN node_names n ON n.pubkey_prefix=t.pubkey_prefix ORDER BY t.id DESC LIMIT 200")
	return $veb.html('templates/table.html')
}

@['/schedules']
pub fn (app &App) schedules(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	scheds := load_schedules(mut db)
	return $veb.html('templates/schedules.html')
}

@['/broadcast']
pub fn (app &App) broadcast(mut ctx Context) veb.Result {
	return $veb.html('templates/broadcast.html')
}

@['/users']
pub fn (app &App) users(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	users := load_users(mut db)
	return $veb.html('templates/users.html')
}


// --- MQTT observer settings ---

@['/mqtt']
pub fn (app &App) mqtt(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	page := mqtt_load(mut db)
	msg := ctx.query['msg'] or { '' }
	err := ctx.query['err'] or { '' }
	return $veb.html('templates/mqtt.html')
}

@['/mqtt/log']
pub fn (app &App) mqtt_log(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	page := mqtt_log_load(mut db, ctx.query['kind'] or { '' }, ctx.query['q'] or { '' }, mqtt_log_limit(ctx.query['limit'] or { '' }))
	return $veb.html('templates/mqtt_log.html')
}

@['/mqtt/log.txt']
pub fn (app &App) mqtt_log_txt(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	page := mqtt_log_load(mut db, ctx.query['kind'] or { '' }, ctx.query['q'] or { '' }, mqtt_log_limit(ctx.query['limit'] or { '' }))
	return ctx.text(mqtt_log_text(page.rows))
}

fn mqtt_back(mut ctx Context, err string) veb.Result {
	if err.len > 0 {
		return ctx.redirect('/mqtt?err=' + urllib.query_escape(err), typ: .found)
	}
	return ctx.redirect('/mqtt?msg=' + urllib.query_escape('Saved. The daemon applies changes within a few seconds.'), typ: .found)
}

@['/mqtt/settings'; post]
pub fn (app &App) mqtt_settings(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/mqtt', typ: .found) }
	defer { db.close() or {} }
	enabled := (ctx.form['enabled'] or { '' }) == '1'
	return mqtt_back(mut ctx, mqtt_save_settings(mut db, enabled, ctx.form['iata'] or { '' }))
}

@['/mqtt/broker/add'; post]
pub fn (app &App) mqtt_broker_add(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/mqtt', typ: .found) }
	defer { db.close() or {} }
	return mqtt_back(mut ctx, mqtt_add_broker(mut db, ctx.form.clone()))
}

@['/mqtt/broker/update'; post]
pub fn (app &App) mqtt_broker_update(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/mqtt', typ: .found) }
	defer { db.close() or {} }
	id := (ctx.form['id'] or { '0' }).int()
	return mqtt_back(mut ctx, mqtt_update_broker(mut db, id, ctx.form.clone()))
}

@['/mqtt/broker/toggle'; post]
pub fn (app &App) mqtt_broker_toggle(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/mqtt', typ: .found) }
	defer { db.close() or {} }
	id := (ctx.form['id'] or { '0' }).int()
	mqtt_toggle_broker(mut db, id, (ctx.form['enabled'] or { '' }) == '1')
	return mqtt_back(mut ctx, '')
}

@['/mqtt/broker/delete'; post]
pub fn (app &App) mqtt_broker_delete(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/mqtt', typ: .found) }
	defer { db.close() or {} }
	mqtt_delete_broker(mut db, (ctx.form['id'] or { '0' }).int())
	return mqtt_back(mut ctx, '')
}

// --- POST actions (PRG: redirect after write) ---

@['/schedules/add'; post]
pub fn (app &App) add_schedule(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/schedules', typ: .found) }
	defer { db.close() or {} }
	target_kind := sanitize(ctx.form['target_kind'] or { 'chan' })
	target := sanitize(ctx.form['target'] or { '' })
	text := ctx.form['text'] or { '' }
	source := sanitize(ctx.form['source'] or { 'static' })
	sched_kind := sanitize(ctx.form['sched_kind'] or { 'daily' })
	interval_secs := (ctx.form['interval_secs'] or { '0' }).i64()
	daily_minute := hhmm_to_minute(ctx.form['daily_hhmm'] or { '' })
	run_at := (ctx.form['run_at'] or { '0' }).i64()
	now := time.now().unix()
	db.exec("INSERT INTO scheduled_messages (target_kind,target,text,source,sched_kind,interval_secs,daily_minute,run_at,last_run,enabled,created) VALUES ('${target_kind}','${target}','${sql_esc(text)}','${source}','${sched_kind}',${interval_secs},${daily_minute},${run_at},0,1,${now})") or {}
	return ctx.redirect('/schedules', typ: .found)
}

@['/schedules/toggle'; post]
pub fn (app &App) toggle_schedule(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/schedules', typ: .found) }
	defer { db.close() or {} }
	id := (ctx.form['id'] or { '0' }).int()
	v := if (ctx.form['enabled'] or { '' }) == '1' { 1 } else { 0 }
	db.exec('UPDATE scheduled_messages SET enabled=${v} WHERE id=${id}') or {}
	return ctx.redirect('/schedules', typ: .found)
}

@['/schedules/delete'; post]
pub fn (app &App) delete_schedule(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/schedules', typ: .found) }
	defer { db.close() or {} }
	id := (ctx.form['id'] or { '0' }).int()
	db.exec('DELETE FROM scheduled_messages WHERE id=${id}') or {}
	return ctx.redirect('/schedules', typ: .found)
}

@['/broadcast/send'; post]
pub fn (app &App) send_broadcast(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/broadcast', typ: .found) }
	defer { db.close() or {} }
	target_kind := sanitize(ctx.form['target_kind'] or { 'chan' })
	target := sanitize(ctx.form['target'] or { '' })
	text := ctx.form['text'] or { '' }
	if text.len > 0 {
		now := time.now().unix()
		db.exec("INSERT INTO outbound_messages (target_kind,target,text,created,sent,sent_ts) VALUES ('${target_kind}','${target}','${sql_esc(text)}',${now},0,0)") or {}
	}
	return ctx.redirect('/broadcast', typ: .found)
}

@['/users/setperm'; post]
pub fn (app &App) set_perm(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/users', typ: .found) }
	defer { db.close() or {} }
	handle := sanitize_handle(ctx.form['handle'] or { '' })
	mut perm := (ctx.form['perm'] or { '2' }).int()
	// clamp to valid Perm range 0..4
	if perm < 0 {
		perm = 0
	}
	if perm > 4 {
		perm = 4
	}
	if handle.len > 0 {
		db.exec("UPDATE users SET perm=${perm} WHERE handle='${handle}'") or {}
	}
	return ctx.redirect('/users', typ: .found)
}

@['/users/ban'; post]
pub fn (app &App) ban_user(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/users', typ: .found) }
	defer { db.close() or {} }
	handle := sanitize_handle(ctx.form['handle'] or { '' })
	banned := if (ctx.form['banned'] or { '' }) == '1' { 1 } else { 0 }
	if handle.len > 0 {
		db.exec("UPDATE users SET banned=${banned} WHERE handle='${handle}'") or {}
	}
	return ctx.redirect('/users', typ: .found)
}

@['/macros/delete'; post]
pub fn (app &App) delete_macro(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.redirect('/macros', typ: .found) }
	defer { db.close() or {} }
	owner := sanitize_handle(ctx.form['owner'] or { '' })
	name := sanitize(ctx.form['name'] or { '' }).to_upper()
	if owner.len > 0 && name.len > 0 {
		db.exec("DELETE FROM user_macros WHERE owner='${owner}' AND name='${name}'") or {}
	}
	return ctx.redirect('/macros', typ: .found)
}

// --- helpers ---

fn (app &App) db() !sqlite.DB {
	return sqlite.connect(app.db_path)!
}

fn scalar(mut db sqlite.DB, q string) string {
	rows := db.exec(q) or { return '?' }
	if rows.len == 0 || rows[0].vals.len == 0 {
		return '0'
	}
	return rows[0].vals[0]
}

fn query_table(mut db sqlite.DB, headers []string, q string) Table {
	rows := db.exec(q) or { return Table{
		headers: headers
		rows:    []
	} }
	mut out := []Row{}
	for r in rows {
		mut cells := []string{}
		for i, v in r.vals {
			// first column of time-based tables is a ts; render nicely if it
			// looks like an epoch and the header says Time
			if i == 0 && headers.len > 0 && headers[0] == 'Time' {
				cells << fmt_ts(v)
			} else {
				cells << v
			}
		}
		out << Row{
			cells: cells
		}
	}
	return Table{
		headers: headers
		rows:    out
	}
}

fn load_users(mut db sqlite.DB) []UserRow {
	rows := db.exec('SELECT handle, perm, banned, last_seen FROM users ORDER BY perm DESC, handle') or {
		return []
	}
	mut out := []UserRow{}
	for r in rows {
		lvl := r.vals[1].int()
		out << UserRow{
			handle:    r.vals[0]
			level:     level_name(lvl)
			level_num: lvl
			banned:    r.vals[2] == '1'
			last_seen: fmt_ts(r.vals[3])
		}
	}
	return out
}

// level_name mirrors the meshbbs Perm enum (0..4).
fn level_name(n int) string {
	return match n {
		0 { 'unverified' }
		1 { 'twit' }
		2 { 'user' }
		3 { 'aide' }
		4 { 'sysop' }
		else { 'user' }
	}
}

// sanitize_handle allows the characters valid in a BBS handle (alphanumerics,
// underscore, dash) and nothing that could break out of the SQL string.
fn sanitize_handle(s string) string {
	mut o := []u8{}
	for c in s {
		if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
			|| c == `_` || c == `-` {
			o << c
		}
	}
	return o.bytestr()
}

fn load_schedules(mut db sqlite.DB) []Sched {
	rows := db.exec('SELECT id, target_kind, target, text, sched_kind, interval_secs, daily_minute, run_at, enabled, source FROM scheduled_messages ORDER BY id') or {
		return []
	}
	mut out := []Sched{}
	for r in rows {
		out << Sched{
			id:      r.vals[0]
			target:  '${r.vals[1]}:${r.vals[2]}'
			text:    r.vals[3]
			source:  r.vals[9]
			kind:    r.vals[4]
			whenv:   schedule_when(r.vals[4], r.vals[5], r.vals[6], r.vals[7])
			enabled: r.vals[8] == '1'
		}
	}
	return out
}

fn schedule_when(kind string, interval_secs string, daily_minute string, run_at string) string {
	return match kind {
		'daily' {
			m := daily_minute.int()
			'${m / 60:02d}:${m % 60:02d} local'
		}
		'interval' {
			'every ${interval_secs}s'
		}
		'onetime' {
			'at ${fmt_ts(run_at)}'
		}
		else {
			'?'
		}
	}
}

fn hhmm_to_minute(s string) int {
	if !s.contains(':') {
		return 0
	}
	parts := s.split(':')
	if parts.len != 2 {
		return 0
	}
	return parts[0].int() * 60 + parts[1].int()
}

fn fmt_ts(s string) string {
	n := s.i64()
	if n <= 0 {
		return '-'
	}
	return time.unix(n).local().format_ss()
}

fn sanitize(s string) string {
	mut o := []u8{}
	for c in s {
		if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) {
			o << c
		}
	}
	return o.bytestr()
}

fn sql_esc(s string) string {
	return s.replace("'", "''")
}

fn main() {
	db_path := if os.args.len > 1 { os.args[1] } else { default_db }
	host := if os.args.len > 2 { os.args[2] } else { default_host }
	port := if os.args.len > 3 { os.args[3].int() } else { default_port }

	if !os.exists(db_path) {
		eprintln('db not found: ${db_path}')
		exit(1)
	}

	mut app := &App{
		db_path: db_path
	}
	println('meshbbs web UI (veb) on http://${host}:${port} (db=${db_path})')
	veb.run_at[App, Context](mut app, host: host, port: port, family: .ip) or { panic(err) }
}
