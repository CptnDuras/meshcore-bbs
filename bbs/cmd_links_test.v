module main

fn links_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	return Engine{
		store: store
		name:  'testbbs'
	}
}

fn test_links_before_any_scan() {
	mut e := links_engine()
	e.handle('aa', 'NEW sysop pw')
	assert e.handle('aa', 'LINKS') == 'No links measured yet.'
}

fn test_links_names_repeaters_from_the_contact_list() {
	mut e := links_engine()
	e.handle('aa', 'NEW sysop pw')
	e.store.upsert_node_name('aa1111111111', 'Hilltop', 2, 100) or { panic(err) }
	e.store.record_link_edge('aa1111111111', link_self, true, 120, 1, 100) or { panic(err) }
	e.store.record_link_hop('aa1111111111', link_self, 8.0, 100) or { panic(err) }
	e.store.record_link_hop(link_self, 'aa1111111111', 6.0, 100) or { panic(err) }
	r := e.handle('aa', 'LINKS')
	assert r.contains('Links: 1 measured')
	assert r.contains('Hilltop<>BBS 8.0/6.0dB 120ms')
}

fn test_a_repeater_without_a_name_shows_the_start_of_its_key() {
	mut e := links_engine()
	e.handle('aa', 'NEW sysop pw')
	e.store.record_link_edge('bb2222222222', link_self, true, 90, 1, 100) or { panic(err) }
	assert e.handle('aa', 'LINKS').contains('bb2222<>BBS')
}

fn test_linkscan_is_for_the_sysop_only() {
	mut e := links_engine()
	e.handle('aa', 'NEW sysop pw') // first user: sysop
	e.handle('bb', 'NEW bob pw') // an ordinary user
	denied := e.handle('bb', 'LINKSCAN')
	assert denied.contains('Permission denied')
	assert e.store.pending_link_scan() == none
	ok := e.handle('aa', 'LINKSCAN')
	assert ok.contains('queued')
	p := e.store.pending_link_scan() or { panic('expected a queued scan') }
	assert p.source == 'sysop'
	// asking twice does not queue twice
	e.handle('aa', 'LINKSCAN')
	assert e.store.recent_link_scans(10).len == 1
}

fn test_link_commands_are_registered_with_help_entries() {
	r := standard_commands()
	assert (r.find('LINKS') or { panic('LINKS missing') }).names == ['LINKS']
	assert (r.find('linkscan') or { panic('LINKSCAN missing') }).names == ['LINKSCAN']
}
