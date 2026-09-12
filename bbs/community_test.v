module main

fn comm_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'commbbs'
	}
}

fn test_oneliner_post_and_list() {
	mut e := comm_engine()
	e.handle('aa', 'NEW sysop pw') // verified
	empty := e.handle('aa', 'ONELINER')
	assert empty.contains('No oneliners')
	e.handle('aa', 'ONELINER hello mesh world')
	list := e.handle('aa', 'O')
	assert list.contains('hello mesh world')
	assert list.contains('sysop')
}

fn test_oneliner_autouser_allowed() {
	// Auto-register: a fresh node is user-level and may post immediately.
	mut e := comm_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('bb', 'HELP') // bb auto-registers as user
	r := e.handle('bb', 'ONELINER hello from bb')
	assert !r.contains('not verified')
	list := e.handle('bb', 'O')
	assert list.contains('hello from bb')
}

fn test_bulletins_sysop_only_post() {
	mut e := comm_engine()
	e.handle('aa', 'NEW sysop pw') // sysop
	e.handle('bb', 'NEW bob pw')
	e.handle('aa', 'VERIFY bob') // bob = user
	// bob cannot post a bulletin
	rb := e.handle('bb', 'BULLET Hi|body')
	assert rb.contains('denied')
	// sysop can
	rp := e.handle('aa', 'BULLET Welcome|Read the rules')
	assert rp.contains('posted')
	// anyone can list
	list := e.handle('bb', 'B')
	assert list.contains('Welcome')
	assert list.contains('Read the rules')
}

fn test_last_callers() {
	mut e := comm_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('bb', 'NEW bob pw')
	// touch logins
	e.handle('aa', 'LOGOUT')
	e.handle('aa', 'LOGIN sysop pw')
	c := e.handle('aa', 'CALLERS')
	assert c.contains('sysop')
	assert c.contains('bob')
}

fn test_tell_delivers_as_mail() {
	mut e := comm_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('bb', 'NEW bob pw')
	e.handle('aa', 'VERIFY bob')
	e.handle('bb', 'LOGIN bob pw')
	r := e.handle('bb', 'TELL sysop hey there')
	assert r.contains('Told sysop')
	// sysop reads mailbox -> sees the TELL
	box := e.handle('aa', 'MAILBOX')
	assert box.contains('[TELL] hey there')
}

fn test_profile_and_setbio() {
	mut e := comm_engine()
	e.handle('aa', 'NEW sysop pw')
	// no bio yet
	p1 := e.handle('aa', 'PROFILE sysop')
	assert p1.contains('no bio set')
	// set a bio
	e.handle('aa', 'SETBIO ham radio + mesh nerd')
	p2 := e.handle('aa', 'PROFILE sysop')
	assert p2.contains('ham radio + mesh nerd')
}

fn test_profile_unknown_user() {
	mut e := comm_engine()
	e.handle('aa', 'NEW sysop pw')
	r := e.handle('aa', 'PROFILE ghost')
	assert r.contains('No such user')
}
