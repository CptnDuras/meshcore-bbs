module main

fn cfg_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'cfgbbs'
	}
}

// --- greeting ---

fn test_first_contact_greeting_shown_once() {
	mut e := cfg_engine()
	r1 := e.handle('aa', 'HELP')
	assert r1.contains('Welcome to')
	// the welcome is a 3-step start and points at guided help (CLAIM/CONFIG live in HELP 5)
	assert r1.contains('Start here') && r1.contains('HELP')
	// second turn: no greeting
	r2 := e.handle('aa', 'HELP')
	assert !r2.contains('Welcome to')
}

// --- custom text-macro commands ---

fn test_config_add_and_invoke_macro() {
	mut e := cfg_engine()
	e.handle('aa', 'HELP') // greet + auto-register
	r := e.handle('aa', 'CONFIG ADDCMD GREET hello from my node')
	assert r.contains('saved')
	// invoking the macro name returns its text
	out := e.handle('aa', 'GREET')
	assert out.contains('hello from my node')
}

fn test_macro_cannot_override_builtin() {
	mut e := cfg_engine()
	e.handle('aa', 'HELP')
	r := e.handle('aa', 'CONFIG ADDCMD WX my fake weather')
	assert r.contains('built-in')
	// WX still runs the real command (not the macro)
	out := e.handle('aa', 'WX')
	assert !out.contains('my fake weather')
}

fn test_macro_is_per_user() {
	mut e := cfg_engine()
	e.handle('aa', 'HELP') // sysop
	e.handle('aa', 'CONFIG ADDCMD MINE aa-only text')
	e.handle('bb', 'HELP') // different node/user
	out := e.handle('bb', 'MINE')
	// bb has no such macro -> unknown command, not aa's text
	assert !out.contains('aa-only text')
}

fn test_config_list_and_delete_macro() {
	mut e := cfg_engine()
	e.handle('aa', 'HELP')
	e.handle('aa', 'CONFIG ADDCMD FOO bar baz')
	list := e.handle('aa', 'CONFIG CMDS')
	assert list.contains('FOO')
	assert list.contains('bar baz')
	del := e.handle('aa', 'CONFIG DELCMD FOO')
	assert del.contains('Removed')
	list2 := e.handle('aa', 'CONFIG CMDS')
	assert !list2.contains('FOO')
}

// --- preferences ---

fn test_config_set_and_list_prefs() {
	mut e := cfg_engine()
	e.handle('aa', 'HELP')
	e.handle('aa', 'CONFIG SET digest on')
	prefs := e.handle('aa', 'CONFIG PREFS')
	assert prefs.contains('digest')
	assert prefs.contains('on')
}

// --- unknown-command hint ---

fn test_unknown_command_suggests() {
	mut e := cfg_engine()
	e.handle('aa', 'HELP')
	// 'HELPP' is one edit from HELP -> should suggest
	r := e.handle('aa', 'HELPP')
	assert r.contains('Did you mean') || r.contains('HELP')
}

fn test_edit_distance() {
	assert edit_distance('HELP', 'HELP') == 0
	assert edit_distance('HELPP', 'HELP') == 1
	assert edit_distance('WX', 'NEWS') > 1
}
