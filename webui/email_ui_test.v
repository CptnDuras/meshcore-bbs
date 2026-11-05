module main

import db.sqlite
import emaillist
import os
import time

// The same tables the daemon's ORM creates (bbs/email_models.v); the column lists come from the shared contract, which bbs/email_store_test.v checks
// against the real ORM.
fn email_fresh_db() sqlite.DB {
	path := os.join_path(os.temp_dir(), 'webui_email_${os.getpid()}_${time.now().unix_nano()}.db')
	db := sqlite.connect(path) or { panic(err) }
	db.exec('CREATE TABLE email_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, descr TEXT NOT NULL, created INTEGER NOT NULL)') or {
		panic(err)
	}
	db.exec('CREATE TABLE email_members (id INTEGER PRIMARY KEY AUTOINCREMENT, group_name TEXT NOT NULL, email TEXT NOT NULL, name TEXT NOT NULL, status TEXT NOT NULL, note TEXT NOT NULL, added INTEGER NOT NULL, last_sent INTEGER NOT NULL, last_error TEXT NOT NULL)') or {
		panic(err)
	}
	db.exec('CREATE TABLE email_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, to_addr TEXT NOT NULL, subject TEXT NOT NULL, body TEXT NOT NULL, group_name TEXT NOT NULL, created INTEGER NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL, next_try INTEGER NOT NULL, last_error TEXT NOT NULL, sent_ts INTEGER NOT NULL, message_id TEXT NOT NULL)') or {
		panic(err)
	}
	return db
}

fn email_cols(mut db sqlite.DB, table string) []string {
	rows := db.exec('PRAGMA table_info(${table})') or { panic(err) }
	return rows.map(it.vals[1])
}

fn test_the_helper_tables_have_the_shared_contract_columns() {
	mut db := email_fresh_db()
	assert email_cols(mut db, 'email_groups') == emaillist.groups_columns
	assert email_cols(mut db, 'email_members') == emaillist.members_columns
	assert email_cols(mut db, 'email_outbox') == emaillist.outbox_columns
}

fn members_of(mut db sqlite.DB, group string) []string {
	return (db.exec_param('SELECT email FROM email_members WHERE group_name=? ORDER BY email', group) or {
		[]sqlite.Row{}
	}).map(it.vals[0])
}

fn status_of(mut db sqlite.DB, group string, email string) string {
	rows := db.exec_param_many('SELECT status FROM email_members WHERE group_name=? AND email=?', [
		group,
		email,
	]) or { []sqlite.Row{} }
	return if rows.len > 0 { rows[0].vals[0] } else { '' }
}

// ---- the page's data ----

fn test_without_the_tables_the_page_says_so() {
	path := os.join_path(os.temp_dir(), 'webui_email_empty_${os.getpid()}.db')
	mut db := sqlite.connect(path) or { panic(err) }
	defer {
		os.rm(path) or {}
	}
	assert email_load(mut db, 1000).available == false
}

fn test_an_empty_database_gives_an_empty_page() {
	mut db := email_fresh_db()
	p := email_load(mut db, 1000)
	assert p.available && p.groups.len == 0 && p.queued == 0 && p.failures.len == 0
}

// ---- groups ----

fn test_a_group_is_made_lower_cased_and_not_made_twice() {
	mut db := email_fresh_db()
	assert email_new_group(mut db, '  Family ', 'The   family', 1000).contains('Group family made')
	assert email_new_group(mut db, 'family', '', 1000).contains('already a group')
	g := email_load(mut db, 1000).groups
	assert g.len == 1 && g[0].name == 'family' && g[0].descr == 'The   family'
}

fn test_bad_group_names_are_refused_and_nothing_is_run_from_them() {
	mut db := email_fresh_db()
	for n in ['', 'a', 'has space', "x'; DROP TABLE email_members;--", 'a'.repeat(25), '<b>'] {
		assert email_new_group(mut db, n, '', 1000).contains('2 to 24 letters'), n
	}
	assert email_load(mut db, 1000).groups.len == 0
	assert email_tables_ready(mut db)
}

fn test_dropping_a_group_needs_confirmation_and_takes_only_its_own_list() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	email_new_group(mut db, 'club', '', 1000)
	email_add_people(mut db, 'family', 'a@example.com', '', 1000)
	email_add_people(mut db, 'club', 'a@example.com\nb@example.com', '', 1000)
	assert email_drop_group(mut db, 'family', false).contains('Tick the box')
	assert members_of(mut db, 'family') == ['a@example.com']
	assert email_drop_group(mut db, 'family', true).contains('removed')
	assert members_of(mut db, 'family').len == 0
	assert members_of(mut db, 'club') == ['a@example.com', 'b@example.com']
	assert email_load(mut db, 1000).groups.map(it.name) == ['club']
	assert email_drop_group(mut db, 'family', true).contains('no group')
}

// ---- adding people ----

fn test_a_pasted_list_is_added_in_every_usual_format() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	msg := email_add_people(mut db, 'family', '# the list\nada@example.com Ada Lovelace\nBOB@Example.com\nCarol Q <carol@example.org>\n\ndan@example.net, Dan\n', 'asked at the meeting', 5000)
	assert msg == '4 added to family.'
	assert members_of(mut db, 'family') == ['ada@example.com', 'bob@example.com', 'carol@example.org',
		'dan@example.net']
	rows := db.exec_param('SELECT name, status, note, added, last_sent, last_error FROM email_members WHERE email=?', 'ada@example.com') or {
		panic(err)
	}
	assert rows[0].vals == ['Ada Lovelace', 'active', 'asked at the meeting', '5000', '0', '']
}

fn test_people_already_there_are_left_exactly_as_they_are() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	email_add_people(mut db, 'family', 'ada@example.com Ada\nbob@example.com', '', 1000)
	email_set_person_status(mut db, 'family', 'ada@example.com', emaillist.member_unsubscribed)
	msg := email_add_people(mut db, 'family', 'ada@example.com Someone Else\nbob@example.com\ncarol@example.org', '', 2000)
	assert msg == '1 added to family, 2 already there.'
	assert status_of(mut db, 'family', 'ada@example.com') == emaillist.member_unsubscribed
	assert (db.exec_param('SELECT name FROM email_members WHERE email=?', 'ada@example.com') or { panic(err) })[0].vals[0] == 'Ada'
}

fn test_the_same_address_in_two_groups_is_two_memberships() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	email_new_group(mut db, 'club', '', 1000)
	email_add_people(mut db, 'family', 'ada@example.com', '', 1000)
	assert email_add_people(mut db, 'club', 'ada@example.com', '', 1000) == '1 added to club.'
}

fn test_lines_that_are_not_addresses_are_reported_and_not_added() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	msg := email_add_people(mut db, 'family', "ada@example.com\nnot a person\nanother bad one\no'brien@example.com\nfourth bad", '', 1000)
	assert msg.starts_with("1 added to family. Not read as an address: not a person; another bad one; o'brien@example.com and 1 more")
	assert members_of(mut db, 'family') == ['ada@example.com']
}

fn test_sql_in_a_pasted_line_is_only_ever_data() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	// the semicolon splits this line like any other separator: "--@example.com" is the address and the rest is its name
	msg := email_add_people(mut db, 'family', "x'); DROP TABLE email_members;--@example.com\nok@example.com\no'brien@example.com", '', 1000)
	assert msg.starts_with('2 added to family.') && msg.contains("Not read as an address: o'brien@example.com")
	assert members_of(mut db, 'family') == ['--@example.com', 'ok@example.com'] && email_tables_ready(mut db)
	name := (db.exec_param('SELECT name FROM email_members WHERE email=?', '--@example.com') or { panic(err) })[0].vals[0]
	assert name.contains('DROP TABLE email_members') // stored as text, never run
}

fn test_adding_to_a_group_that_is_not_there_or_nothing_at_all() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	assert email_add_people(mut db, 'nope', 'a@example.com', '', 1000).contains('no group called nope')
	assert email_add_people(mut db, "x' OR '1'='1", 'a@example.com', '', 1000).contains('no group')
	assert email_add_people(mut db, 'family', '   \n\n', '', 1000).contains('Nothing to add')
	assert members_of(mut db, 'family') == []
}

fn test_one_paste_adds_at_most_500_people() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'big', '', 1000)
	mut lines := []string{}
	for i in 0 .. 520 {
		lines << 'p${i}@example.com'
	}
	msg := email_add_people(mut db, 'big', lines.join('\n'), '', 1000)
	assert msg.starts_with('500 added to big, 20 left out (at most 500 at a time)')
	assert members_of(mut db, 'big').len == 500
}

fn test_a_note_cannot_carry_markup_or_be_long() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	email_add_people(mut db, 'family', 'a@example.com', 'asked "at" <b>the</b> meeting' + 'x'.repeat(100), 1000)
	note := (db.exec('SELECT note FROM email_members') or { panic(err) })[0].vals[0]
	assert !note.contains('"') && !note.contains('<') && note.len <= 60
}

// ---- removing and stopping ----

fn test_a_person_is_removed_from_one_group_only() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	email_new_group(mut db, 'club', '', 1000)
	email_add_people(mut db, 'family', 'a@example.com\nb@example.com', '', 1000)
	email_add_people(mut db, 'club', 'a@example.com', '', 1000)
	assert email_remove_person(mut db, 'family', ' A@Example.com ') == 'Removed a@example.com from family.'
	assert members_of(mut db, 'family') == ['b@example.com'] && members_of(mut db, 'club') == ['a@example.com']
	assert email_remove_person(mut db, 'family', 'a@example.com').contains('is not in family')
}

fn test_stop_and_start_change_only_that_person() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	email_add_people(mut db, 'family', 'a@example.com\nb@example.com', '', 1000)
	assert email_set_person_status(mut db, 'family', 'a@example.com', emaillist.member_unsubscribed).contains('no more mail')
	assert status_of(mut db, 'family', 'a@example.com') == 'unsubscribed' && status_of(mut db, 'family', 'b@example.com') == 'active'
	g := email_load(mut db, 1000).groups[0]
	assert g.total == 2 && g.active == 1
	assert email_set_person_status(mut db, 'family', 'a@example.com', emaillist.member_active).contains('again')
	assert status_of(mut db, 'family', 'a@example.com') == 'active'
}

fn test_starting_a_rejected_person_clears_the_error_so_they_are_tried_again() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	email_add_people(mut db, 'family', 'a@example.com', '', 1000)
	db.exec_param_many("UPDATE email_members SET status='rejected', last_error='Email address is not verified' WHERE email=?", [
		'a@example.com',
	]) or { panic(err) }
	p := email_load(mut db, 1000).groups[0].members[0]
	assert p.is_rejected && !p.is_active && p.error == 'Email address is not verified'
	email_set_person_status(mut db, 'family', 'a@example.com', emaillist.member_active)
	q := email_load(mut db, 1000).groups[0].members[0]
	assert q.is_active && q.error == ''
}

fn test_an_unknown_state_or_person_changes_nothing() {
	mut db := email_fresh_db()
	email_new_group(mut db, 'family', '', 1000)
	email_add_people(mut db, 'family', 'a@example.com', '', 1000)
	assert email_set_person_status(mut db, 'family', 'a@example.com', 'rejected') == 'Unknown state.'
	assert email_set_person_status(mut db, 'family', 'z@example.com', emaillist.member_active).contains('is not in family')
	assert status_of(mut db, 'family', 'a@example.com') == 'active'
}

// ---- the sending summary ----

fn test_the_queue_summary_counts_and_lists_failures() {
	mut db := email_fresh_db()
	for row in [['a@example.com', 'queued', '0'], ['b@example.com', 'sent', '900'],
		['c@example.com', 'sent', '10'], ['d@example.com', 'failed', '0']] {
		db.exec_param_many("INSERT INTO email_outbox (to_addr, subject, body, group_name, created, status, attempts, next_try, last_error, sent_ts, message_id) VALUES (?, 's', 'b', 'g', 1, ?, 0, 0, ?, ?, '')", [
			row[0],
			row[1],
			if row[1] == 'failed' { 'Email address is not verified' } else { '' },
			row[2],
		]) or { panic(err) }
	}
	p := email_load(mut db, 1000)
	assert p.queued == 1 && p.sent == 2 && p.failed == 1
	assert p.sent_day == 2 // both sent within a day of "now" (1000)
	assert p.failures == ['d@example.com: Email address is not verified']
	assert email_load(mut db, 900 + 86401).sent_day == 0
}

// ---- the form guard ----

fn test_a_post_from_another_site_is_refused() {
	assert email_same_origin('', '100.118.159.79:8080') // not a browser (curl, tests)
	assert email_same_origin('http://100.118.159.79:8080', '100.118.159.79:8080')
	assert !email_same_origin('https://evil.example', '100.118.159.79:8080')
	assert !email_same_origin('http://100.118.159.79:8081', '100.118.159.79:8080')
	assert !email_same_origin('http://100.118.159.79:8080.evil.example', '100.118.159.79:8080')
}

// ---- what the template prints ----

fn test_everything_from_the_database_is_escaped_exactly_once() {
	mut db := email_fresh_db()
	// written straight into the table, the way the daemon (which does not strip markup) could
	db.exec_param_many('INSERT INTO email_groups (name, descr, created) VALUES (?, ?, 1)', [
		'club',
		'Tom & "Jerry" <b>',
	]) or { panic(err) }
	db.exec_param_many("INSERT INTO email_members (group_name, email, name, status, note, added, last_sent, last_error) VALUES ('club', 'a@example.com', ?, 'rejected', '', 1, 0, ?)", [
		"O'Brien <script>alert(1)</script> & co",
		'refused: "x" <y>',
	]) or { panic(err) }
	db.exec_param_many("INSERT INTO email_outbox (to_addr, subject, body, group_name, created, status, attempts, next_try, last_error, sent_ts, message_id) VALUES ('b@example.com', 's', 'b', 'club', 1, 'failed', 0, 0, '<i>bad</i> & worse', 0, '')", []string{}) or {
		panic(err)
	}
	p := email_load(mut db, 1000)
	assert string(p.groups[0].descr) == 'Tom &amp; &quot;Jerry&quot; &lt;b&gt;'
	m := p.groups[0].members[0]
	assert string(m.name) == 'O&#39;Brien &lt;script&gt;alert(1)&lt;/script&gt; &amp; co'
	assert string(m.error) == 'refused: &quot;x&quot; &lt;y&gt;'
	assert p.failures.map(string(it)) == ['b@example.com: &lt;i&gt;bad&lt;/i&gt; &amp; worse']
	assert string(esc('<img src=x onerror=1> & "q"')) == '&lt;img src=x onerror=1&gt; &amp; &quot;q&quot;'
}
