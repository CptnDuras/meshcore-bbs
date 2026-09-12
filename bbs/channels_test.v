module main

fn chan_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'chanbbs'
	}
}

fn test_channels_empty() {
	mut e := chan_engine()
	r := e.handle('aa', 'CHANNELS')
	assert r.contains('empty')
}

fn test_channel_add_and_list() {
	mut e := chan_engine()
	e.handle('aa', 'NEW sysop pw') // verified
	r := e.handle('aa', 'CHANADD BuffaloMesh|Local Buffalo WY mesh|meshtastic.org/e/#abc')
	assert r.contains('Added channel')
	list := e.handle('bb', 'CHANNELS')
	assert list.contains('BuffaloMesh')
	assert list.contains('Local Buffalo WY mesh')
	assert list.contains('meshtastic.org/e/#abc')
}

fn test_channel_add_without_info() {
	mut e := chan_engine()
	e.handle('aa', 'NEW sysop pw')
	r := e.handle('aa', 'CHANADD Emergency|County emergency net')
	assert r.contains('Added channel')
	list := e.handle('aa', 'CHANNELS')
	assert list.contains('Emergency')
	assert list.contains('County emergency net')
}

fn test_channel_add_autouser_allowed() {
	// Auto-register: a fresh node is user-level and may add channels.
	mut e := chan_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('bb', 'HELP') // bb auto-registers as user
	r := e.handle('bb', 'CHANADD BBNet|Buffalo net')
	assert !r.contains('not verified')
	assert r.contains('Added channel')
}

fn test_channel_add_usage() {
	mut e := chan_engine()
	e.handle('aa', 'NEW sysop pw')
	r := e.handle('aa', 'CHANADD onlyname')
	assert r.contains('Usage')
}

fn test_channel_duplicate_rejected() {
	mut e := chan_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'CHANADD Dup|first')
	r := e.handle('aa', 'CHANADD Dup|second')
	assert r.contains('already listed')
}
