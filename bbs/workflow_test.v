module main

fn wf_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'wfbbs'
	}
}

fn test_multipacket_entry_posts() {
	mut e := wf_engine()
	e.handle('aa', 'NEW sysop pw') // verified sysop
	e.handle('aa', 'C general')
	start := e.handle('aa', 'E My Subject')
	assert start.contains('Send . alone')
	// accumulate lines
	e.handle('aa', 'line one')
	e.handle('aa', 'line two')
	fin := e.handle('aa', '.')
	assert fin.contains('posted')
	// verify the message exists with both lines
	board := e.store.get_board('general') or {
		assert false, 'general'
		return
	}
	msgs := e.store.board_messages(board.id, 10)
	assert msgs.len == 1
	assert msgs[0].body.contains('line one')
	assert msgs[0].body.contains('line two')
	assert msgs[0].subject == 'My Subject'
}

fn test_entry_line_not_parsed_as_command() {
	mut e := wf_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'C general')
	e.handle('aa', 'E subj')
	// a line that looks like a command should be treated as message text
	r := e.handle('aa', 'HELP me please')
	assert r.contains('entry')
	e.handle('aa', '.')
	board := e.store.get_board('general') or {
		assert false, ''
		return
	}
	msgs := e.store.board_messages(board.id, 10)
	assert msgs[0].body.contains('HELP me please')
}

fn test_mail_send_and_read() {
	mut e := wf_engine()
	e.handle('aa', 'NEW sysop pw') // sysop
	e.handle('bb', 'NEW bob pw') // unverified
	e.handle('aa', 'VERIFY bob') // bob now user
	// bob logs in and mails sysop
	e.handle('bb', 'LOGIN bob pw')
	ms := e.handle('bb', 'MAIL sysop')
	assert ms.contains('Enter mail')
	e.handle('bb', 'hello sysop')
	e.handle('bb', 'this is private')
	fin := e.handle('bb', '.')
	assert fin.contains('Mail sent')
	// sysop reads mailbox
	box := e.handle('aa', 'MAILBOX')
	assert box.contains('from bob')
	assert box.contains('hello sysop')
}

fn test_mail_notice_on_login() {
	mut e := wf_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('bb', 'NEW bob pw')
	e.handle('aa', 'VERIFY bob')
	e.handle('bb', 'LOGIN bob pw')
	// bob mails sysop
	e.handle('bb', 'MAIL sysop')
	e.handle('bb', 'ping')
	e.handle('bb', '.')
	// sysop logs out then in -> should see mail notice
	e.handle('aa', 'LOGOUT')
	login := e.handle('aa', 'LOGIN sysop pw')
	assert login.contains('new mail')
}

fn test_mail_unknown_recipient() {
	mut e := wf_engine()
	e.handle('aa', 'NEW sysop pw')
	// Mail-anyone: mailing a never-before-seen handle auto-creates a mailbox
	// and prompts for the body (no longer rejected as 'No such user').
	r := e.handle('aa', 'MAIL ghost')
	assert r.contains('Enter mail to ghost')
	if _ := e.store.get_user('ghost') {
		// mailbox auto-created
	} else {
		assert false, 'ghost mailbox should have been auto-created'
	}
}

fn test_empty_entry_discarded() {
	mut e := wf_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'C general')
	e.handle('aa', 'E subj')
	// immediately end with '.' -> empty
	r := e.handle('aa', '.')
	assert r.contains('Empty message discarded')
}
