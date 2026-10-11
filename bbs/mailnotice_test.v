module main

fn mail_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'MESHBBS'
	}
}

// --- CHECKMAIL ---

fn test_checkmail_no_mail() {
	mut e := mail_engine()
	e.handle('aa', 'HELP') // auto-register sysop
	r := e.handle('aa', 'CHECKMAIL')
	assert r.contains('No mail')
}

fn test_checkmail_shows_unread_without_marking_read() {
	mut e := mail_engine()
	e.handle('aa', 'NEW sysop pw') // sysop, handle 'sysop'
	e.handle('bb', 'NEW bob pw') // bob (user)
	// bob mails sysop
	e.handle('bb', 'MAIL sysop')
	e.handle('bb', 'hello there')
	e.handle('bb', '.')
	// sysop CHECKMAIL: shows 1 unread
	c := e.handle('aa', 'CHECKMAIL')
	assert c.contains('1 new mail')
	// still unread afterward (checkmail must NOT mark read)
	assert e.store.unread_mail_count('sysop') == 1
	// MAILBOX marks read
	e.handle('aa', 'MAILBOX')
	assert e.store.unread_mail_count('sysop') == 0
	// now checkmail says no new
	c2 := e.handle('aa', 'CHECKMAIL')
	assert c2.contains('No new mail')
}

// --- pure should_notify_mail ---

fn test_notify_none_when_no_unread() {
	assert should_notify_mail(0, 0, 0, 1000) == false
}

fn test_notify_first_time() {
	assert should_notify_mail(2, 0, 0, 1000) == true
}

fn test_notify_when_count_grows() {
	// already notified at count 1; now 3 unread -> notify again
	assert should_notify_mail(3, 500, 1, 600) == true
}

fn test_no_notify_within_cooldown_same_count() {
	// notified recently, same count -> suppress
	assert should_notify_mail(1, 1000, 1, 1000 + 60) == false
}

fn test_notify_after_cooldown() {
	assert should_notify_mail(1, 1000, 1, 1000 + mail_notice_cooldown) == true
}

// --- maybe_mail_notice engine path (guard records + suppresses repeats) ---

fn test_maybe_notice_records_and_suppresses_repeat() {
	mut e := mail_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('bb', 'NEW bob pw')
	e.handle('bb', 'MAIL sysop')
	e.handle('bb', 'yo')
	e.handle('bb', '.')
	now := i64(100000)
	// first advert-time check -> notice
	n1 := e.maybe_mail_notice('sysop', now)
	assert n1.contains('new mail')
	// immediate repeat (same count, within cooldown) -> suppressed
	n2 := e.maybe_mail_notice('sysop', now + 60)
	assert n2 == ''
	// after cooldown -> notice again
	n3 := e.maybe_mail_notice('sysop', now + mail_notice_cooldown)
	assert n3.contains('new mail')
}

fn test_maybe_notice_empty_when_no_mail() {
	mut e := mail_engine()
	e.handle('aa', 'NEW sysop pw')
	assert e.maybe_mail_notice('sysop', 1000) == ''
}
