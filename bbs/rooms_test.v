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
	// fresh session: no room picked yet, so N works in the default room (general)
	r := e.handle('aa', 'N')
	assert !r.contains('not in a room')
	assert r.contains('No new messages') || r.contains('first')
}

fn test_read_without_a_room_uses_general_not_the_first_room() {
	mut e := nav_engine() // lobby is created first, general second
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POST general|Hi|hello general')
	e.handle('aa', 'POST lobby|Yo|hello lobby')
	r := e.handle('aa', 'R')
	assert r.contains('== general ==')
	assert r.contains('hello general')
	assert !r.contains('hello lobby')
}

fn test_read_without_a_room_reads_the_current_room() {
	mut e := nav_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POST general|Hi|hello general')
	e.handle('aa', 'POST lobby|Yo|hello lobby')
	e.handle('aa', 'C lobby')
	r := e.handle('aa', 'R')
	assert r.contains('== lobby ==')
	assert r.contains('hello lobby')
}

fn test_read_with_a_room_still_works_and_switches_rooms() {
	mut e := nav_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POST general|Hi|hello general')
	e.handle('aa', 'POST lobby|Yo|hello lobby')
	assert e.handle('aa', 'R lobby').contains('hello lobby')
	// now in lobby: a bare R stays there
	assert e.handle('aa', 'R').contains('== lobby ==')
	// and back
	assert e.handle('aa', 'R general').contains('hello general')
	assert e.handle('aa', 'R').contains('== general ==')
	assert e.handle('aa', 'R nowhere').contains('No such room')
}

fn test_post_without_picking_a_room_goes_to_general() {
	mut e := nav_engine()
	e.handle('aa', 'NEW sysop pw')
	assert e.handle('aa', 'E first post').contains('. alone')
	e.handle('aa', 'body of it')
	e.handle('aa', '.')
	assert e.handle('aa', 'R general').contains('body of it')
	assert !e.handle('aa', 'R lobby').contains('body of it')
}

fn test_default_room_falls_back_to_the_first_room_without_general() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('cafe', 'Cafe') or {}
	mut e := Engine{
		store: store
		name:  'nogeneral'
	}
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POST cafe|Hi|latte')
	assert e.handle('aa', 'R').contains('== cafe ==')
}

fn test_read_with_no_rooms_at_all() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	mut e := Engine{
		store: store
		name:  'empty'
	}
	e.handle('aa', 'NEW sysop pw')
	assert e.handle('aa', 'R').contains('No rooms yet')
}
