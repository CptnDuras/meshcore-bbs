module main

fn ar_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'arbbs'
	}
}

fn test_first_node_bootstraps_sysop() {
	mut e := ar_engine()
	e.handle('aa', 'HELP') // first contact -> auto account
	u := e.store.get_user('node-aa') or {
		assert false, 'node-aa missing'
		return
	}
	assert perm_from_int(u.perm) == Perm.sysop
}

fn test_second_node_is_user() {
	mut e := ar_engine()
	e.handle('aa', 'HELP') // sysop bootstrap
	e.handle('bb', 'HELP') // auto user
	u := e.store.get_user('node-bb') or {
		assert false, 'node-bb missing'
		return
	}
	assert perm_from_int(u.perm) == Perm.user
}

fn test_autouser_can_post_without_registering() {
	mut e := ar_engine()
	e.handle('aa', 'HELP') // sysop
	r := e.handle('bb', 'POST general|Hi|body') // bb auto-user
	assert r.contains('Posted')
}

fn test_claim_renames_account_and_keeps_perm() {
	mut e := ar_engine()
	e.handle('aa', 'HELP') // aa is bootstrap sysop as node-aa
	r := e.handle('aa', 'CLAIM alice secret')
	assert r.contains('Claimed') || r.contains('now alice') || r.contains('alice')
	// old node handle gone, new handle present, perm preserved (sysop)
	if _ := e.store.get_user('node-aa') {
		assert false, 'node-aa should have been renamed'
	}
	u := e.store.get_user('alice') or {
		assert false, 'alice missing'
		return
	}
	assert perm_from_int(u.perm) == Perm.sysop
}

fn test_claim_then_login_from_other_device() {
	mut e := ar_engine()
	e.handle('aa', 'HELP')
	e.handle('aa', 'CLAIM alice secret')
	// a different node logs in as alice (adopts identity; no multi-pubkey link)
	r := e.handle('zz', 'LOGIN alice secret')
	assert r.contains('Welcome')
}

fn test_claim_rejects_taken_handle() {
	mut e := ar_engine()
	e.handle('aa', 'CLAIM alice secret') // aa -> alice (sysop)
	e.handle('bb', 'HELP') // bb auto user
	r := e.handle('bb', 'CLAIM alice pw2')
	assert r.contains('taken')
}

fn test_new_command_claims_for_unclaimed_node() {
	mut e := ar_engine()
	// NEW on an unclaimed node names it (claim path)
	r := e.handle('aa', 'NEW alice secret')
	assert r.contains('alice')
	u := e.store.get_user('alice') or {
		assert false, 'alice missing'
		return
	}
	assert perm_from_int(u.perm) == Perm.sysop // first node kept sysop
}

fn test_display_name_helper() {
	assert display_name('node-4b81424f7106') == 'guest-4b81'
	assert display_name('alice') == 'alice'
	assert is_node_handle('node-abc') == true
	assert is_node_handle('alice') == false
}
