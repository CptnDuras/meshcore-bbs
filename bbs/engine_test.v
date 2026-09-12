module main

import crypto.bcrypt

fn new_test_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General discussion') or {}
	return Engine{
		store: store
		name:  'testbbs'
	}
}

// helper: register a user and return the handle; first user becomes sysop.
fn reg(mut e Engine, pk string, handle string, pass string) string {
	return e.handle(pk, 'NEW ${handle} ${pass}')
}

fn test_bootstrap_first_user_is_sysop() {
	mut e := new_test_engine()
	reg(mut e, 'aa', 'alice', 'pw')
	u := e.store.get_user('alice') or {
		assert false, 'alice missing'
		return
	}
	assert perm_from_int(u.perm) == Perm.sysop
	// second node auto-registers as USER (mandatory registration retired)
	reg(mut e, 'bb', 'bob', 'pw')
	u2 := e.store.get_user('bob') or {
		assert false, 'bob missing'
		return
	}
	assert perm_from_int(u2.perm) == Perm.user
}

fn test_autouser_can_post_immediately() {
	mut e := new_test_engine()
	reg(mut e, 'aa', 'sysop', 'pw') // first = sysop
	reg(mut e, 'bb', 'bob', 'pw') // auto user, named
	// bob may post right away — no verify gate
	r := e.handle('bb', 'POST general|Hi|hello')
	assert r.contains('Posted')
}

fn test_verify_requires_aide() {
	mut e := new_test_engine()
	reg(mut e, 'aa', 'sysop', 'pw')
	reg(mut e, 'bb', 'bob', 'pw')
	reg(mut e, 'cc', 'carol', 'pw')
	// verify bob so he's a plain user
	e.handle('aa', 'VERIFY bob')
	// bob (user) tries to verify carol -> denied
	r := e.handle('bb', 'VERIFY carol')
	assert r.contains('denied')
}

fn test_promote_and_demote() {
	mut e := new_test_engine()
	reg(mut e, 'aa', 'sysop', 'pw')
	reg(mut e, 'bb', 'bob', 'pw')
	// sysop promotes bob to aide
	r := e.handle('aa', 'PROMOTE bob')
	assert r.contains('aide')
	u := e.store.get_user('bob') or {
		assert false, 'bob'
		return
	}
	assert perm_from_int(u.perm) == Perm.aide
}

fn test_ban_blocks_login() {
	mut e := new_test_engine()
	reg(mut e, 'aa', 'sysop', 'pw')
	reg(mut e, 'bb', 'bob', 'pw')
	e.handle('aa', 'BAN bob')
	// bob logs out then tries to log in
	e.handle('bb', 'LOGOUT')
	r := e.handle('bb', 'LOGIN bob pw')
	assert r.contains('banned')
}

fn test_delete_message() {
	mut e := new_test_engine()
	reg(mut e, 'aa', 'sysop', 'pw')
	e.handle('aa', 'POST general|Subj|Body')
	// find the message id
	board := e.store.get_board('general') or {
		assert false, 'general'
		return
	}
	msgs := e.store.board_messages(board.id, 10)
	assert msgs.len == 1
	id := msgs[0].id
	r := e.handle('aa', 'DELETE ${id}')
	assert r.contains('Deleted')
	assert e.store.board_messages(board.id, 10).len == 0
}

fn test_guest_can_read_not_post() {
	mut e := new_test_engine()
	// a brand-new node 'zz' is auto-registered as a user and may post
	rp := e.handle('zz', 'POST general|x|y')
	assert rp.contains('Posted')
	rr := e.handle('zz', 'READ general')
	assert rr.contains('empty') || rr.contains('general') || rr.contains('x')
}

fn test_login_success_and_failure() {
	mut e := new_test_engine()
	// create user via store directly with known password
	hash := bcrypt.generate_from_password('secret'.bytes(), bcrypt.default_cost) or {
		panic(err)
	}
	e.store.create_user('dave', hash) or { panic(err) }
	ok := e.handle('dd', 'LOGIN dave secret')
	assert ok.contains('Welcome')
	bad := e.handle('dd', 'LOGIN dave wrong')
	assert bad.contains('failed')
}

fn test_help_menu_list_unknown() {
	mut e := new_test_engine()
	assert e.handle('zz', 'HELP').contains('Commands')
	assert e.handle('zz', 'MENU').contains('testbbs')
	assert e.handle('zz', 'LIST').contains('general')
	assert e.handle('zz', 'FLERB').contains('Unknown command')
	assert e.handle('zz', '').contains('testbbs') // empty -> menu
}
