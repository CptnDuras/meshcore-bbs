module main

fn email_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'MESHBBS'
	}
}

// the first account is the sysop ('aa'); 'bb' is an ordinary user
fn email_engine_with_users() Engine {
	mut e := email_engine()
	e.handle('aa', 'NEW boss pw')
	e.handle('bb', 'NEW bob pw')
	return e
}

// (reading a pasted list, addresses and group names are tested in emaillist/emaillist_test.v)

fn test_a_subject_comes_from_the_first_line_of_the_message() {
	assert subject_from_text('Storm warning\nmore text', 'x') == 'Storm warning'
	assert subject_from_text('   \n  ', 'fallback') == 'fallback'
	assert subject_from_text('w'.repeat(100), 'x') == 'w'.repeat(70) + '...'
}

fn test_the_body_greets_by_name_and_ends_with_why_and_how_to_stop() {
	b := compose_email_body('MESHBBS', 'family', 'Ada', 'Net tonight at 7.')
	assert b.starts_with('Hello Ada,\n\nNet tonight at 7.')
	assert b.contains('asked to be on the family list of MESHBBS')
	assert b.contains('reply to this email and say STOP')
	assert !compose_email_body('MESHBBS', 'family', '', 'Hi').starts_with('Hello')
}

fn test_a_very_long_message_is_cut() {
	b := compose_email_body('M', 'g', '', 'x'.repeat(9000))
	assert b.contains('[cut]') && b.len < 5600
}

// ---- the sysop's commands ----

fn test_only_the_sysop_can_manage_groups_or_send() {
	mut e := email_engine_with_users()
	for cmd in ['GROUPS', 'GROUP NEW club', 'GROUP club LIST', 'GSEND club hi', 'EMAILSTATUS'] {
		assert e.handle('bb', cmd) == email_admin_denied, cmd
	}
	assert e.store.list_email_groups().len == 0
}

fn test_a_group_is_made_listed_and_dropped() {
	mut e := email_engine_with_users()
	assert e.handle('aa', 'GROUPS').contains('No email groups')
	assert e.handle('aa', 'GROUP NEW family The family list').contains('created')
	assert e.handle('aa', 'GROUP NEW family').contains('already exists')
	assert e.handle('aa', 'GROUP NEW x').contains('2-24')
	assert e.handle('aa', 'GROUPS').contains('family: 0 active of 0 - The family list')
	assert e.handle('aa', 'GROUP DROP family').contains('removed')
	assert e.handle('aa', 'GROUP DROP family').contains('No group')
}

fn test_members_are_added_listed_stopped_started_and_removed() {
	mut e := email_engine_with_users()
	e.handle('aa', 'GROUP NEW family')
	assert e.handle('aa', 'GROUP family ADD Ada@Example.com Ada Lovelace').contains('Added ada@example.com')
	assert e.handle('aa', 'GROUP family ADD ada@example.com').contains('already in')
	assert e.handle('aa', 'GROUP family ADD nonsense').contains('does not look like')
	assert e.handle('aa', 'GROUP family ADD bob@example.com').contains('Added')
	list := e.handle('aa', 'GROUP family LIST')
	assert list.contains('ada@example.com (Ada Lovelace)') && list.contains('bob@example.com')
	assert e.handle('aa', 'GROUP family STOP ada@example.com').contains('no more email')
	assert e.handle('aa', 'GROUP family LIST').contains('ada@example.com (Ada Lovelace) [unsubscribed]')
	assert e.handle('aa', 'GROUPS').contains('family: 1 active of 2')
	assert e.handle('aa', 'GROUP family START ada@example.com').contains('back on')
	assert e.handle('aa', 'GROUP family DEL bob@example.com').contains('Removed')
	assert e.handle('aa', 'GROUP family DEL bob@example.com').contains('not in')
	assert e.handle('aa', 'GROUP nogroup LIST').contains('No group')
}

fn test_an_unsubscribed_person_added_again_stays_unsubscribed() {
	mut e := email_engine_with_users()
	e.handle('aa', 'GROUP NEW family')
	e.handle('aa', 'GROUP family ADD ada@example.com')
	e.handle('aa', 'GROUP family STOP ada@example.com')
	assert e.handle('aa', 'GROUP family ADD ada@example.com').contains('already in')
	m := e.store.get_email_member('family', 'ada@example.com') or { panic('gone') }
	assert m.status == member_unsubscribed
}

// ---- sending ----

fn test_gsend_asks_for_the_message_and_queues_one_email_per_active_member() {
	mut e := email_engine_with_users()
	e.handle('aa', 'GROUP NEW family')
	e.handle('aa', 'GROUP family ADD ada@example.com Ada')
	e.handle('aa', 'GROUP family ADD bob@example.com')
	e.handle('aa', 'GROUP family ADD carol@example.com')
	e.handle('aa', 'GROUP family STOP carol@example.com')
	assert e.handle('aa', 'GSEND family Net tonight').contains('Enter the message for family')
	e.handle('aa', 'Net at 7 on the usual channel.')
	r := e.handle('aa', '.')
	assert r.contains('Queued 2 emails to family')
	queued := e.store.due_emails(i64(9999999999), 10)
	assert queued.map(it.to_addr) == ['ada@example.com', 'bob@example.com']
	assert queued[0].subject == 'Net tonight'
	assert queued[0].body.starts_with('Hello Ada,\n\nNet at 7 on the usual channel.')
	assert !queued[1].body.starts_with('Hello')
	assert queued[0].group_name == 'family'
}

fn test_gsend_without_a_subject_uses_the_first_line() {
	mut e := email_engine_with_users()
	e.handle('aa', 'GROUP NEW family')
	e.handle('aa', 'GROUP family ADD ada@example.com')
	e.handle('aa', 'GSEND family')
	e.handle('aa', 'Heavy snow on the pass\ndrive carefully')
	e.handle('aa', '.')
	assert e.store.due_emails(i64(9999999999), 1)[0].subject == 'Heavy snow on the pass'
}

fn test_gsend_to_nobody_or_nowhere_queues_nothing() {
	mut e := email_engine_with_users()
	e.handle('aa', 'GROUP NEW empty')
	assert e.handle('aa', 'GSEND nogroup hi').contains('No group')
	e.handle('aa', 'GSEND empty hi')
	e.handle('aa', 'message')
	assert e.handle('aa', '.').contains('no active members')
	assert e.store.count_emails(email_queued) == 0
}

fn test_an_empty_gsend_is_discarded() {
	mut e := email_engine_with_users()
	e.handle('aa', 'GROUP NEW family')
	e.handle('aa', 'GROUP family ADD ada@example.com')
	e.handle('aa', 'GSEND family')
	assert e.handle('aa', '.').contains('Empty message discarded')
	assert e.store.count_emails(email_queued) == 0
}

fn test_a_scheduled_message_aimed_at_an_email_group_fans_out() {
	mut e := email_engine_with_users()
	e.handle('aa', 'GROUP NEW family')
	e.handle('aa', 'GROUP family ADD ada@example.com')
	om := OutboundMessage{
		target_kind: target_email
		target:      'family'
		text:        'Daily digest\nweather: sunny'
	}
	assert e.email_outbound(om, 1000) == ''
	q := e.store.due_emails(2000, 5)
	assert q.len == 1 && q[0].subject == 'Daily digest' && q[0].body.contains('weather: sunny')
	assert e.email_outbound(OutboundMessage{ ...om, target: 'nope' }, 1000).contains('no email group')
}

fn test_email_status_shows_the_queue_and_recent_failures() {
	mut e := email_engine_with_users()
	e.store.enqueue_email('a@example.com', 's', 'b', 'g', 1000) or { panic(err) }
	e.store.enqueue_email('b@example.com', 's', 'b', 'g', 1000) or { panic(err) }
	q := e.store.due_emails(2000, 5)
	e.store.mark_email_failed(q[1].id, 'Email address is not verified') or { panic(err) }
	s := e.handle('aa', 'EMAILSTATUS')
	assert s.contains('queued 1, sent 0, failed 1') && s.contains('b@example.com: Email address is not verified')
}
