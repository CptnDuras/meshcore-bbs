module main

// Set up an engine with a verified sysop + a second room and some messages.
fn nav_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('lobby', 'The Lobby') or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'navbbs'
	}
}

fn test_known_rooms_lists_with_markers() {
	mut e := nav_engine()
	e.handle('aa', 'NEW sysop pw') // sysop, verified
	// no messages yet -> all '-'
	k := e.handle('aa', 'K')
	assert k.contains('lobby')
	assert k.contains('general')
	assert k.contains('-')
}

fn test_change_room_and_new_messages() {
	mut e := nav_engine()
	e.handle('aa', 'NEW sysop pw')
	// post into general
	e.handle('aa', 'POST general|Hi|first')
	e.handle('aa', 'POST general|Yo|second')
	// change to general
	c := e.handle('aa', 'C general')
	assert c.contains('general')
	// N shows the two unread
	n1 := e.handle('aa', 'N')
	assert n1.contains('first')
	assert n1.contains('second')
	// second N -> nothing new (pointer advanced)
	n2 := e.handle('aa', 'N')
	assert n2.contains('No new messages')
}

fn test_goto_next_unread() {
	mut e := nav_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POST general|Hi|hello')
	// start in lobby
	e.handle('aa', 'C lobby')
	// G should jump to general (which has unread) and show the message
	g := e.handle('aa', 'G')
	assert g.contains('general')
	assert g.contains('hello')
	// now nothing unread -> G reports none
	g2 := e.handle('aa', 'G')
	assert g2.contains('No unread')
}

fn test_known_rooms_marks_unread_star() {
	mut e := nav_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POST general|Hi|hello')
	// sysop authored it; unread_count counts id>pointer regardless of author,
	// so general should show unread until read.
	k := e.handle('aa', 'K')
	// general line should have a '*'
	assert k.contains('* general')
}

fn test_change_room_unknown() {
	mut e := nav_engine()
	e.handle('aa', 'NEW sysop pw')
	r := e.handle('aa', 'C nonexistent')
	assert r.contains('No such room')
}

fn test_new_without_room() {
	mut e := nav_engine()
	e.handle('aa', 'NEW sysop pw')
	// fresh session, current_board 0
	r := e.handle('aa', 'N')
	assert r.contains('not in a room')
}
