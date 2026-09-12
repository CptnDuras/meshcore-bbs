module main

fn polls_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'pollbbs'
	}
}

fn test_poll_create_and_show() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw') // first user -> sysop (verified)
	r := e.handle('aa', 'POLL NEW Best band?|Rush|Yes|Genesis')
	assert r.contains('created')
	assert r.contains('#1')
	// show it
	show := e.handle('bb', 'POLL 1')
	assert show.contains('Best band?')
	assert show.contains('1) Rush')
	assert show.contains('2) Yes')
	assert show.contains('3) Genesis')
}

fn test_poll_list() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw')
	empty := e.handle('aa', 'POLL')
	assert empty.contains('No polls')
	e.handle('aa', 'POLL NEW Coffee or tea?|Coffee|Tea')
	list := e.handle('aa', 'POLLS')
	assert list.contains('#1')
	assert list.contains('Coffee or tea?')
}

fn test_poll_create_autouser_allowed() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw') // sysop
	e.handle('bb', 'HELP') // bb auto-registers as user
	r := e.handle('bb', 'POLL NEW x?|a|b')
	assert !r.contains('not verified')
	assert r.contains('created')
}

fn test_poll_create_needs_two_options() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw')
	r := e.handle('aa', 'POLL NEW OnlyOne?|single')
	assert r.contains('at least 2 options') || r.contains('Usage')
}

fn test_vote_and_results() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POLL NEW Best band?|Rush|Yes|Genesis')
	// three different nodes vote
	v1 := e.handle('aa', 'VOTE 1 1')
	assert v1.contains('recorded')
	e.handle('bb', 'VOTE 1 1')
	e.handle('cc', 'VOTE 1 3')
	res := e.handle('aa', 'RESULTS 1')
	assert res.contains('Total votes: 3')
	assert res.contains('1) Rush: 2')
	assert res.contains('3) Genesis: 1')
}

fn test_double_vote_rejected() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POLL NEW x?|a|b')
	first := e.handle('bb', 'VOTE 1 1')
	assert first.contains('recorded')
	second := e.handle('bb', 'VOTE 1 2')
	assert second.contains('already voted')
	// tally still shows a single vote
	res := e.handle('aa', 'RESULTS 1')
	assert res.contains('Total votes: 1')
}

fn test_vote_out_of_range() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POLL NEW x?|a|b')
	r := e.handle('bb', 'VOTE 1 9')
	assert r.contains('out of range')
}

fn test_vote_unknown_poll() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw')
	r := e.handle('aa', 'VOTE 99 1')
	assert r.contains('no such poll')
}

fn test_poll_close_blocks_votes() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POLL NEW x?|a|b')
	c := e.handle('aa', 'POLLCLOSE 1')
	assert c.contains('closed')
	r := e.handle('bb', 'VOTE 1 1')
	assert r.contains('closed')
}

fn test_poll_close_permission() {
	mut e := polls_engine()
	e.handle('aa', 'NEW sysop pw') // sysop, author of poll
	e.handle('bb', 'NEW bob pw')
	e.handle('aa', 'VERIFY bob') // bob = user
	e.handle('aa', 'POLL NEW x?|a|b') // poll #1 by sysop
	// bob (a plain user, not author, not aide) cannot close it
	e.handle('bb', 'LOGIN bob pw')
	r := e.handle('bb', 'POLLCLOSE 1')
	assert r.contains('author or an aide')
}
