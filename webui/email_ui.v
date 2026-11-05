module main

// Email groups page (/email): who is on each list, add and remove people, stop or restart one, and a look at the sending queue. The page only reads and
// writes the shared DB; the daemon's worker sends the mail (bbs/email_worker.v). Reading a pasted list and checking addresses is the shared
// emaillist module, so this page accepts exactly what the daemon's `meshbbs email import` does.

import db.sqlite
import emaillist
import net.urllib
import time
import veb

const email_max_people_per_paste = 500

// Everything the template prints from the database or the address bar is HTML-escaped here, once, and handed over as veb.RawHtml. Whether veb escapes
// strings itself depends on the V build (this one does, an older one may not), and escaping twice shows people "&amp;#39;"; RawHtml is the one thing
// no build escapes again.
fn esc(s string) veb.RawHtml {
	return veb.RawHtml(h(s))
}

struct EmailMemberView {
	email       veb.RawHtml
	name        veb.RawHtml
	status      veb.RawHtml
	is_active   bool
	is_rejected bool
	last_sent   veb.RawHtml
	error       veb.RawHtml
}

struct EmailGroupView {
	name    veb.RawHtml
	descr   veb.RawHtml
	total   int
	active  int
	members []EmailMemberView
}

struct EmailPage {
	available bool
	groups    []EmailGroupView
	queued    int
	sent      int
	failed    int
	sent_day  int
	failures  []veb.RawHtml
}

fn email_tables_ready(mut db sqlite.DB) bool {
	for t in ['email_groups', 'email_members', 'email_outbox'] {
		db.exec('SELECT 1 FROM ${t} LIMIT 1') or { return false }
	}
	return true
}

fn email_count(mut db sqlite.DB, sql_text string, param string) int {
	return email_count_many(mut db, sql_text, [param])
}

// every value goes in as a bound parameter, never into the SQL text
fn email_count_many(mut db sqlite.DB, sql_text string, params []string) int {
	rows := db.exec_param_many(sql_text, params) or { return 0 }
	if rows.len == 0 || rows[0].vals.len == 0 {
		return 0
	}
	return rows[0].vals[0].int()
}

fn email_has_member(mut db sqlite.DB, group string, email string) bool {
	return email_count_many(mut db, 'SELECT COUNT(*) FROM email_members WHERE group_name=? AND email=?', [
		group,
		email,
	]) > 0
}

fn email_load(mut db sqlite.DB, now i64) EmailPage {
	if !email_tables_ready(mut db) {
		return EmailPage{}
	}
	mut groups := []EmailGroupView{}
	for g in db.exec('SELECT name, descr FROM email_groups ORDER BY name') or { []sqlite.Row{} } {
		mut members := []EmailMemberView{}
		mut active := 0
		for m in db.exec_param('SELECT email, name, status, last_sent, last_error FROM email_members WHERE group_name=? ORDER BY email',
			g.vals[0]) or { []sqlite.Row{} } {
			is_active := m.vals[2] == emaillist.member_active
			if is_active {
				active++
			}
			members << EmailMemberView{
				email:       esc(m.vals[0])
				name:        esc(m.vals[1])
				status:      esc(m.vals[2])
				is_active:   is_active
				is_rejected: m.vals[2] == emaillist.member_rejected
				last_sent:   esc(if m.vals[3].i64() > 0 { fmt_ts(m.vals[3]) } else { '' })
				error:       esc(m.vals[4])
			}
		}
		groups << EmailGroupView{
			name:    esc(g.vals[0])
			descr:   esc(g.vals[1])
			total:   members.len
			active:  active
			members: members
		}
	}
	mut failures := []veb.RawHtml{}
	for f in db.exec("SELECT to_addr, last_error FROM email_outbox WHERE status='failed' ORDER BY id DESC LIMIT 5") or {
		[]sqlite.Row{}
	} {
		failures << esc('${f.vals[0]}: ${f.vals[1]}')
	}
	return EmailPage{
		available: true
		groups:    groups
		queued:    email_count(mut db, 'SELECT COUNT(*) FROM email_outbox WHERE status=?', 'queued')
		sent:      email_count(mut db, 'SELECT COUNT(*) FROM email_outbox WHERE status=?', 'sent')
		failed:    email_count(mut db, 'SELECT COUNT(*) FROM email_outbox WHERE status=?', 'failed')
		sent_day:  email_count(mut db, "SELECT COUNT(*) FROM email_outbox WHERE status='sent' AND sent_ts>=?",
			(now - 86400).str())
		failures:  failures
	}
}

// ---- changes: each returns the sentence the page shows afterwards ----

fn email_group_exists(mut db sqlite.DB, name string) bool {
	return email_count(mut db, 'SELECT COUNT(*) FROM email_groups WHERE name=?', name) > 0
}

fn email_new_group(mut db sqlite.DB, raw_name string, descr string, now i64) string {
	name := raw_name.trim_space().to_lower()
	if !emaillist.valid_group_name(name) {
		return 'Group names are 2 to 24 letters, digits, - or _.'
	}
	if email_group_exists(mut db, name) {
		return 'There is already a group called ${name}.'
	}
	db.exec_param_many('INSERT INTO email_groups (name, descr, created) VALUES (?, ?, ?)', [
		name,
		emaillist.clean_name(descr),
		now.str(),
	]) or { return 'Could not make the group: ${err.msg()}' }
	return 'Group ${name} made. Add people to it below.'
}

fn email_drop_group(mut db sqlite.DB, name string, confirmed bool) string {
	if !email_group_exists(mut db, name) {
		return 'There is no group called ${name}.'
	}
	if !confirmed {
		return 'Tick the box to confirm before removing a group and its list.'
	}
	db.exec_param('DELETE FROM email_members WHERE group_name=?', name) or {
		return 'Could not remove the list: ${err.msg()}'
	}
	db.exec_param('DELETE FROM email_groups WHERE name=?', name) or {
		return 'Could not remove the group: ${err.msg()}'
	}
	return 'Group ${name} and its list were removed.'
}

// Adds everyone in the pasted text (the same formats as `meshbbs email import`). Someone already in the group, including someone who unsubscribed, is left
// exactly as they are.
fn email_add_people(mut db sqlite.DB, group string, text string, note string, now i64) string {
	if !email_group_exists(mut db, group) {
		return 'There is no group called ${group}.'
	}
	list := emaillist.parse_member_list(text)
	if list.people.len == 0 && list.bad.len == 0 {
		return 'Nothing to add: paste one person a line.'
	}
	mut added := 0
	mut there := 0
	take := if list.people.len > email_max_people_per_paste {
		email_max_people_per_paste
	} else {
		list.people.len
	}
	for p in list.people[..take] {
		if email_has_member(mut db, group, p.email) {
			there++
			continue
		}
		db.exec_param_many('INSERT INTO email_members (group_name, email, name, status, note, added, last_sent, last_error) VALUES (?, ?, ?, ?, ?, ?, 0, ?)', [
			group,
			p.email,
			p.name,
			emaillist.member_active,
			emaillist.clean_name(note),
			now.str(),
			'',
		]) or { return 'Stopped after ${added} added: ${err.msg()}' }
		added++
	}
	mut out := '${added} added to ${group}'
	if there > 0 {
		out += ', ${there} already there'
	}
	if list.people.len > email_max_people_per_paste {
		out += ', ${list.people.len - email_max_people_per_paste} left out (at most ${email_max_people_per_paste} at a time)'
	}
	if list.bad.len > 0 {
		out += '. Not read as an address: ' + list.bad[..if list.bad.len > 3 {
			3
		} else {
			list.bad.len
		}].join('; ')
		if list.bad.len > 3 {
			out += ' and ${list.bad.len - 3} more'
		}
	}
	return out + '.'
}

fn email_remove_person(mut db sqlite.DB, group string, raw_email string) string {
	email := emaillist.normalize_email(raw_email)
	if !email_has_member(mut db, group, email) {
		return '${email} is not in ${group}.'
	}
	db.exec_param2('DELETE FROM email_members WHERE group_name=? AND email=?', group, email) or {
		return 'Could not remove ${email}: ${err.msg()}'
	}
	return 'Removed ${email} from ${group}.'
}

// status is emaillist.member_unsubscribed (stop mailing them) or member_active (start again, also for one SES had refused)
fn email_set_person_status(mut db sqlite.DB, group string, raw_email string, status string) string {
	email := emaillist.normalize_email(raw_email)
	if status !in [emaillist.member_active, emaillist.member_unsubscribed] {
		return 'Unknown state.'
	}
	if !email_has_member(mut db, group, email) {
		return '${email} is not in ${group}.'
	}
	db.exec_param_many("UPDATE email_members SET status=?, last_error='' WHERE group_name=? AND email=?", [
		status,
		group,
		email,
	]) or { return 'Could not change ${email}: ${err.msg()}' }
	return if status == emaillist.member_active {
		'${email} will get mail from ${group} again.'
	} else {
		'${email} will get no more mail from ${group}.'
	}
}

// A form post must come from this page: when the browser says where it came from (Origin), that has to be this server, so another site cannot make
// a browser on the tailnet change the list.
fn email_same_origin(origin string, host string) bool {
	if origin == '' {
		return true // not a browser form post (curl, tests)
	}
	return origin.all_after('://') == host
}

// ---- routes ----

fn email_back(mut ctx Context, msg string) veb.Result {
	return ctx.redirect('/email?msg=' + urllib.query_escape(msg), typ: .found)
}

fn email_guard(mut ctx Context) bool {
	origin := ctx.req.header.get(.origin) or { '' }
	host := ctx.req.header.get(.host) or { '' }
	return email_same_origin(origin, host)
}

@['/email']
pub fn (app &App) email(mut ctx Context) veb.Result {
	mut db := app.db() or { return ctx.text('db error') }
	defer { db.close() or {} }
	page := email_load(mut db, time.now().unix())
	msg := esc(ctx.query['msg'] or { '' })
	return $veb.html('templates/email.html')
}

@['/email/group'; post]
pub fn (app &App) email_group(mut ctx Context) veb.Result {
	if !email_guard(mut ctx) {
		return email_back(mut ctx, 'That request did not come from this page.')
	}
	mut db := app.db() or { return email_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	return email_back(mut ctx, email_new_group(mut db, ctx.form['name'] or { '' }, ctx.form['descr'] or {
		''
	}, time.now().unix()))
}

@['/email/drop'; post]
pub fn (app &App) email_drop(mut ctx Context) veb.Result {
	if !email_guard(mut ctx) {
		return email_back(mut ctx, 'That request did not come from this page.')
	}
	mut db := app.db() or { return email_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	return email_back(mut ctx, email_drop_group(mut db, ctx.form['group'] or { '' }, (ctx.form['sure'] or {
		''
	}) == 'yes'))
}

@['/email/add'; post]
pub fn (app &App) email_add(mut ctx Context) veb.Result {
	if !email_guard(mut ctx) {
		return email_back(mut ctx, 'That request did not come from this page.')
	}
	mut db := app.db() or { return email_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	return email_back(mut ctx, email_add_people(mut db, ctx.form['group'] or { '' }, ctx.form['people'] or {
		''
	}, ctx.form['note'] or { '' }, time.now().unix()))
}

@['/email/remove'; post]
pub fn (app &App) email_remove(mut ctx Context) veb.Result {
	if !email_guard(mut ctx) {
		return email_back(mut ctx, 'That request did not come from this page.')
	}
	mut db := app.db() or { return email_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	return email_back(mut ctx, email_remove_person(mut db, ctx.form['group'] or { '' }, ctx.form['email'] or {
		''
	}))
}

@['/email/stop'; post]
pub fn (app &App) email_stop(mut ctx Context) veb.Result {
	if !email_guard(mut ctx) {
		return email_back(mut ctx, 'That request did not come from this page.')
	}
	mut db := app.db() or { return email_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	return email_back(mut ctx, email_set_person_status(mut db, ctx.form['group'] or { '' }, ctx.form['email'] or {
		''
	}, emaillist.member_unsubscribed))
}

@['/email/start'; post]
pub fn (app &App) email_start(mut ctx Context) veb.Result {
	if !email_guard(mut ctx) {
		return email_back(mut ctx, 'That request did not come from this page.')
	}
	mut db := app.db() or { return email_back(mut ctx, 'db error') }
	defer { db.close() or {} }
	return email_back(mut ctx, email_set_person_status(mut db, ctx.form['group'] or { '' }, ctx.form['email'] or {
		''
	}, emaillist.member_active))
}
