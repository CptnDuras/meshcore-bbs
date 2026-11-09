module main

fn audit_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'auditbbs'
	}
}

fn test_interaction_is_logged() {
	mut e := audit_engine()
	e.handle('nodeAA', 'HELP')
	rows := e.store.recent_interactions(10)
	assert rows.len == 1
	assert rows[0].pubkey_prefix == 'nodeAA'
	assert rows[0].command == 'HELP'
	assert rows[0].text == 'HELP'
	assert rows[0].reply_len > 0
	assert rows[0].ts > 0
}

fn test_interaction_logs_every_turn() {
	mut e := audit_engine()
	e.handle('nodeAA', 'HELP')
	e.handle('nodeAA', 'WX')
	e.handle('nodeBB', 'MENU')
	assert e.store.count_interactions() == 3
}

fn test_interaction_resolves_handle_when_logged_in() {
	mut e := audit_engine()
	// register (becomes sysop) -> handle is set on the session
	e.handle('nodeAA', 'NEW sysop pw')
	// a subsequent command should log with the resolved handle
	e.handle('nodeAA', 'LIST')
	rows := e.store.recent_interactions(10)
	// most recent first
	assert rows[0].command == 'LIST'
	assert rows[0].handle == 'sysop'
}

fn test_interaction_autouser_has_node_handle() {
	mut e := audit_engine()
	e.handle('nodeGuest', 'LIST')
	rows := e.store.recent_interactions(10)
	assert rows[0].pubkey_prefix == 'nodeGuest'
	// auto-register assigns an unclaimed node- handle (no longer empty)
	assert rows[0].handle == 'node-nodeGuest'
}

fn test_interaction_menu_token_for_empty_line() {
	mut e := audit_engine()
	e.handle('nodeAA', '')
	rows := e.store.recent_interactions(10)
	assert rows[0].command == '(menu)'
}

fn test_interaction_senders_distinct() {
	mut e := audit_engine()
	e.handle('aa', 'HELP')
	e.handle('aa', 'WX')
	e.handle('bb', 'HELP')
	e.handle('cc', 'MENU')
	senders := e.store.interaction_senders()
	assert senders.len == 3
	assert 'aa' in senders
	assert 'bb' in senders
	assert 'cc' in senders
}

// Guard: the audit log must NOT be reachable from any BBS command. We probe a
// set of plausible query commands and assert none of them return audit data.
// If a future change wires the table into dispatch, this test should fail.
fn test_audit_log_not_exposed_to_callers() {
	mut e := audit_engine()
	e.handle('secretNode', 'HELP') // create an audit row with a distinctive id
	// A sysop is the highest-privileged caller; even they must not be able to
	// pull interaction rows through the command interface.
	e.handle('adminNode', 'NEW sysop pw')

	probes := ['STATS', 'LOG', 'LOGS', 'AUDIT', 'INTERACTIONS', 'HISTORY', 'SEEN', 'SEEN secretNode',
		'TRACK', 'WHOIS secretNode']
	for p in probes {
		resp := e.handle('adminNode', p)
		// The distinctive sender prefix from the audit row must never surface,
		// and the response should be the standard unknown-command message for
		// commands that aren't part of the BBS.
		assert !resp.contains('secretNode'), 'command "${p}" leaked audit data: ${resp}'
	}
}

// The help/menu text must not advertise any audit/log command either.
fn test_help_does_not_mention_audit() {
	mut e := audit_engine()
	e.handle('adminNode', 'NEW sysop pw')
	help := e.handle('adminNode', 'HELP')
	lower := help.to_lower()
	assert !lower.contains('audit')
	assert !lower.contains('interaction')
}
