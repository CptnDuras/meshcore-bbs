module main

// Tests for the mailbox enhancements:
//   1. MAIL-ANYONE + AUTO-MAILBOX
//   2. THREAD <handle> conversation view (both directions, re-readable)
//   3. @<partial> recipient resolution (registered users first, then nodes)

fn mbox_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'MBOX'
	}
}

// --- 1. MAIL to a never-before-seen handle auto-creates a mailbox + stores mail ---

fn test_mail_anyone_autocreates_mailbox_and_stores() {
	mut e := mbox_engine()
	e.handle('aa', 'NEW sysop pw') // sysop, handle 'sysop'
	// mail a handle that has never contacted the BBS
	r := e.handle('aa', 'MAIL stranger')
	assert r.contains('Enter mail to stranger')
	// mailbox auto-created
	u := e.store.get_user('stranger') or {
		assert false, 'stranger mailbox should exist'
		return
	}
	assert perm_from_int(u.perm) == Perm.user
	assert u.pass_hash == '' // unclaimed
	// finish the message -> stored for the recipient
	e.handle('aa', 'hello stranger')
	e.handle('aa', '.')
	mails := e.store.list_mail('stranger', 10)
	assert mails.len == 1
	assert mails[0].body == 'hello stranger'
	assert mails[0].from_handle == 'sysop'
}

// --- 2. THREAD shows both directions, oldest->newest, and is re-readable ---

fn test_thread_shows_both_directions_in_order() {
	mut e := mbox_engine()
	e.handle('aa', 'NEW sysop pw') // sysop
	e.handle('bb', 'NEW bob pw') // bob (user)
	// bob -> sysop
	e.handle('bb', 'MAIL sysop')
	e.handle('bb', 'hi sysop')
	e.handle('bb', '.')
	// sysop -> bob
	e.handle('aa', 'MAIL bob')
	e.handle('aa', 'hi bob')
	e.handle('aa', '.')
	// bob -> sysop again
	e.handle('bb', 'MAIL sysop')
	e.handle('bb', 'thanks')
	e.handle('bb', '.')

	t := e.handle('aa', 'THREAD bob')
	assert t.contains('Thread: bob')
	// both directions present
	assert t.contains('< from them: hi sysop')
	assert t.contains('> to them: hi bob')
	assert t.contains('< from them: thanks')
	// order oldest->newest
	i1 := t.index('hi sysop') or { -1 }
	i2 := t.index('hi bob') or { -1 }
	i3 := t.index('thanks') or { -1 }
	assert i1 >= 0 && i2 > i1 && i3 > i2

	// re-readable: THREAD must NOT mark mail read (sysop had 2 unread from bob)
	assert e.store.unread_mail_count('sysop') == 2
	// and a second THREAD returns the same content
	t2 := e.handle('aa', 'THREAD bob')
	assert t2.contains('hi sysop')
	assert e.store.unread_mail_count('sysop') == 2
}

// --- 3a. @<partial> resolves a unique registered user ---

fn test_at_partial_unique_resolves() {
	mut e := mbox_engine()
	e.handle('aa', 'NEW sysop pw') // sysop
	e.handle('bb', 'NEW alice pw') // alice registered
	r := e.handle('aa', 'MAIL @ali')
	assert r.contains('Enter mail to alice')
}

// --- 3b. @<partial> with multiple matches lists candidates ---

fn test_at_partial_multiple_lists_candidates() {
	mut e := mbox_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('bb', 'NEW alice pw')
	e.handle('cc', 'NEW alan pw')
	r := e.handle('aa', 'MAIL @al')
	assert r.contains('Multiple:')
	assert r.contains('alice')
	assert r.contains('alan')
	assert r.contains('be more specific')
}

// --- 3c. @<partial> with no match reports no match ---

fn test_at_partial_no_match() {
	mut e := mbox_engine()
	e.handle('aa', 'NEW sysop pw')
	r := e.handle('aa', 'MAIL @zzz')
	assert r.contains('No match for @zzz')
}

// --- 3d. registered users take priority; seen node names also resolvable ---

fn test_at_partial_resolves_seen_node_name() {
	mut e := mbox_engine()
	e.handle('aa', 'NEW sysop pw')
	// a seen node advertised the name 'nomad' (no registered account)
	e.store.upsert_node_name('ff', 'nomad', 0, 0) or {}
	r := e.handle('aa', 'MAIL @nom')
	assert r.contains('Enter mail to nomad')
}

// --- THREAD also supports @<partial> ---

fn test_thread_at_partial_resolves() {
	mut e := mbox_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('bb', 'NEW alice pw')
	// sysop mails alice so there is a thread
	e.handle('aa', 'MAIL alice')
	e.handle('aa', 'hey')
	e.handle('aa', '.')
	t := e.handle('aa', 'THREAD @ali')
	assert t.contains('Thread: alice')
	assert t.contains('> to them: hey')
}
