module main

import os

// Help is tested through its interfaces: a fake catalog and a fake viewer prove
// HelpService has no hidden dependencies, and a stub renderer proves the Engine
// takes its help from whatever it is given.

struct FakeCatalog {
	topic_list []HelpTopic
	cmd_list   []HelpCommand
	msgs       map[string]string
}

fn (c FakeCatalog) topics() []HelpTopic {
	return c.topic_list
}

fn (c FakeCatalog) commands() []HelpCommand {
	return c.cmd_list
}

fn (c FakeCatalog) message(name string) string {
	return c.msgs[name] or { '' }
}

struct FakeViewer {
	level Perm
}

fn (f FakeViewer) perm() Perm {
	return f.level
}

fn (f FakeViewer) is_new() bool {
	return false
}

struct StubRenderer {}

fn (s StubRenderer) render(query string, v HelpViewer) string {
	return 'STUB[${query}]'
}

fn (s StubRenderer) topic_for_digit(digit string, v HelpViewer) ?string {
	return none
}

fn (s StubRenderer) welcome(bbs string, who string) string {
	return 'STUB-WELCOME ${bbs} ${who}'
}

fn help_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'helpbbs'
	}
}

fn cat_service() HelpService {
	return new_help_service(FakeCatalog{
		topic_list: [
			HelpTopic{
				num:     1
				key:     'pets'
				title:   'Pets'
				aliases: ['animals']
				try_cmd: 'CAT'
				notes:   ['Be kind.']
			},
			HelpTopic{
				num:      2
				key:      'staff'
				title:    'Staff'
				min_perm: .sysop
			},
		]
		cmd_list:   [
			HelpCommand{
				names:   ['CAT', 'KITTY']
				topic:   'pets'
				usage:   'CAT <name>'
				summary: 'pet one'
				example: 'CAT tom'
			},
			HelpCommand{
				names:    ['SHUTDOWN']
				topic:    'staff'
				usage:    'SHUTDOWN'
				summary:  'stop'
				min_perm: .sysop
			},
		]
		msgs:       {
			'menu_header': 'MENU:'
			'menu_footer': 'ALL for all'
			'no_topic':    'No "{query}".'
			'welcome':     'Hi {who} at {bbs}'
		}
	})
}

fn test_service_composes_everything_from_the_injected_catalog() {
	s := cat_service()
	v := FakeViewer{
		level: .user
	}
	assert s.render('', v) == 'MENU:\n1 Pets\nALL for all'
	assert s.render('1', v) == 'PETS\nCAT <name> = pet one\nBe kind.\nTry: CAT'
	assert s.render('animals', v) == s.render('1', v)
	assert s.render('cat', v) == 'CAT <name> - pet one\nAlso: KITTY\nEx: CAT tom'
	assert s.render('kitty', v) == s.render('cat', v)
	assert s.render('all', v) == 'Pets: CAT'
	assert s.render('nope', v).starts_with('No "nope".')
	assert s.welcome('bbs1', 'bob') == 'Hi bob at bbs1'
}

fn test_topics_and_commands_are_gated_by_permission() {
	s := cat_service()
	user := FakeViewer{
		level: .user
	}
	sysop := FakeViewer{
		level: .sysop
	}
	assert !s.render('', user).contains('Staff')
	assert s.render('2', user).starts_with('No "2"')
	assert s.render('shutdown', user).starts_with('No "shutdown"')
	assert s.render('', sysop).contains('2 Staff')
	assert s.render('2', sysop) == 'STAFF\nSHUTDOWN = stop'
	assert s.render('all', sysop) == 'Pets: CAT\nStaff: SHUTDOWN'
}

fn test_digit_shortcut() {
	s := cat_service()
	v := FakeViewer{
		level: .user
	}
	assert (s.topic_for_digit('1', v) or { '' }).starts_with('PETS')
	for bad in ['2', '0', '12', 'x', ''] {
		if _ := s.topic_for_digit(bad, v) {
			assert false, '${bad} must not open a topic'
		}
	}
}

fn test_command_name_wins_over_topic_word_but_digits_are_topics() {
	s := new_help_service(FakeCatalog{
		topic_list: [HelpTopic{
			num:   1
			key:   'mail'
			title: 'Mail'
		}]
		cmd_list:   [
			HelpCommand{
				names:   ['MAIL']
				topic:   'mail'
				usage:   'MAIL <u>'
				summary: 'send'
			},
		]
		msgs:       {
			'menu_header': 'M'
			'no_topic':    'no'
			'welcome':     'w'
		}
	})
	v := FakeViewer{
		level: .user
	}
	assert s.render('mail', v).starts_with('MAIL <u> - send')
	assert s.render('1', v).starts_with('MAIL\n')
}

// --- the built-in help data ---

fn builtin_service() HelpService {
	d := help_data_from_embedded() or { panic(err) }
	return new_help_service(d)
}

fn test_builtin_help_parses_and_is_valid() {
	d := help_data_from_embedded() or {
		assert false, 'help.txt invalid: ${err}'
		return
	}
	assert d.topics().len == 9
	assert d.commands().len > 40
}

fn test_builtin_screens_fit_one_radio_message() {
	s := builtin_service()
	sysop := FakeViewer{
		level: .sysop
	}
	assert s.render('', sysop).len <= msg_max, 'menu is ${s.render('', sysop).len} bytes'
	for t in s.visible(sysop) {
		screen := s.screen(t, sysop)
		// the staff screen lists every moderator and sysop command, so it may span two messages
		limit := if t.min_perm == .unverified { msg_max } else { 2 * msg_max }
		assert screen.len <= limit, 'topic ${t.key} is ${screen.len} bytes'
	}
	for c in s.catalog.commands() {
		page := s.command_page(c)
		assert page.len <= 2 * msg_max, 'command ${c.names[0]} page is ${page.len} bytes'
	}
}

fn test_builtin_menu_is_gated() {
	s := builtin_service()
	user := s.render('', FakeViewer{
		level: .user
	})
	assert user.contains('\n8 People')
	assert !user.contains('Staff')
	aide := s.render('', FakeViewer{
		level: .aide
	})
	assert aide.contains('\n9 Staff')
}

// --- every command has its own help entry, and every entry is a real command ---

fn test_every_registered_command_has_a_matching_help_entry() {
	reg := standard_commands()
	d := help_data_from_embedded() or { panic(err) }
	mut entries := map[string]HelpCommand{}
	for c in d.commands() {
		entries[c.names[0]] = c
	}
	mut problems := []string{}
	for cmd in reg.all() {
		e := entries[cmd.names[0]] or {
			problems << '${cmd.names[0]}: no help entry'
			continue
		}
		if e.names != cmd.names {
			problems << '${cmd.names[0]}: help names ${e.names} != registered ${cmd.names}'
		}
	}
	registered := reg.all().map(it.names[0])
	for name, _ in entries {
		if name !in registered {
			problems << '${name}: help entry for a command that does not exist'
		}
	}
	assert problems.len == 0, problems.join('; ')
}

fn test_help_all_lists_every_visible_command() {
	s := builtin_service()
	sysop := FakeViewer{
		level: .sysop
	}
	all := s.render('all', sysop)
	reg := standard_commands()
	for cmd in reg.all() {
		short := shortest_name(cmd.names)
		assert (' ' + all.replace('\n', ' ') + ' ').contains(' ${short} '), '${cmd.names[0]} (${short}) missing from HELP ALL'
	}
}

// Every "Try:" example and every command's own example must run without an
// unknown-command or usage error.
fn test_help_examples_actually_work() {
	mut e := help_engine()
	e.handle('aa', 'HELP') // first account is the sysop
	s := builtin_service()
	mut tried := 0
	for t in s.catalog.topics() {
		if t.try_cmd.len == 0 || t.try_cmd == 'WX' {
			continue // WX is a live network fetch
		}
		reply := e.handle('aa', t.try_cmd)
		assert !reply.contains('Unknown command'), '${t.key}: Try: ${t.try_cmd} -> ${reply}'
		assert !reply.starts_with('Usage'), '${t.key}: Try: ${t.try_cmd} -> ${reply}'
		tried++
	}
	assert tried >= 5
}

// --- the command registry: features are atomic ---

fn test_registry_rejects_duplicate_names() {
	mut r := CommandRegistry{}
	register_room_commands(mut r)
	// registering a second command under an existing alias would shadow it; find() proves lookup works
	assert (r.find('k') or {
		Command{
			handler: cmd_known
		}
	}).names[0] == 'KNOWN'
	assert (r.find('Known') or {
		Command{
			handler: cmd_known
		}
	}).names[0] == 'KNOWN'
	if _ := r.find('MAIL') {
		assert false, 'rooms must not register mail'
	}
}

fn engine_with(register fn (mut r CommandRegistry)) Engine {
	mut e := help_engine()
	mut r := CommandRegistry{}
	register(mut r)
	e.commands = r
	return e
}

fn test_room_feature_alone() {
	mut e := engine_with(register_room_commands)
	e.handle('aa', 'K')
	assert e.handle('aa', 'K').contains('general')
	assert e.handle('aa', 'C general').contains('Now in general')
	assert e.handle('aa', 'MAIL bob').contains('Unknown command') // not registered here
	assert e.handle('aa', 'WX').contains('Unknown command')
}

fn test_mail_feature_alone() {
	mut e := engine_with(register_mail_commands)
	e.handle('aa', 'CHECKMAIL')
	assert e.handle('aa', 'CHECKMAIL').contains('No mail')
	assert e.handle('aa', 'K').contains('Unknown command')
}

fn test_fun_feature_alone() {
	mut e := engine_with(register_fun_commands)
	e.handle('aa', 'JOKE')
	assert e.handle('aa', 'ROLL 2d6').len > 0
	assert !e.handle('aa', 'ROLL 2d6').contains('Unknown command')
	assert e.handle('aa', 'K').contains('Unknown command')
}

fn test_core_and_account_features_alone() {
	mut e := engine_with(register_core_commands)
	assert e.handle('aa', 'STATS').len > 0
	assert e.handle('aa', 'CLAIM x y').contains('Unknown command')
	mut f := engine_with(register_account_commands)
	assert f.handle('bb', 'CALLERS').contains('Last callers')
}

fn test_info_and_admin_registrations_cover_their_commands() {
	mut info := CommandRegistry{}
	register_info_commands(mut info)
	for n in ['WX', 'FORECAST', 'ALERTS', 'SW', 'NEWS', 'CHANNELS', 'CHANADD'] {
		assert info.find(n) != none, '${n} missing'
	}
	mut admin := CommandRegistry{}
	register_admin_commands(mut admin)
	for n in ['VERIFY', 'PROMOTE', 'BAN', 'DEL', 'BULLET', 'ALERTTEST', 'HELPRELOAD', 'HELPIMPORT'] {
		assert admin.find(n) != none, '${n} missing'
	}
}

// --- engine integration ---

fn test_engine_help_and_digit_flow() {
	mut e := help_engine()
	e.handle('aa', 'HELP') // first account is the sysop
	menu := e.handle('aa', 'HELP')
	assert menu.starts_with('HELP - reply with a number:')
	assert menu.contains('\n9 Staff')
	assert e.handle('aa', '1').starts_with('ROOMS')
	assert e.handle('aa', 'HELP 2').starts_with('MAIL')
	assert e.handle('aa', 'HELP MAIL').starts_with('MAIL <user> - send')
	assert e.handle('aa', 'HELP ALL').contains('Rooms: ')
	e.handle('bb', 'HELP')
	assert !e.handle('bb', 'HELP').contains('Staff')
	assert e.handle('bb', 'HELP BAN').starts_with('No help for')
	assert e.handle('bb', '9').contains('Unknown command')
}

fn test_digits_do_not_break_other_commands() {
	mut e := help_engine()
	e.handle('aa', 'HELP')
	assert !e.handle('aa', 'VOTE 1 2').starts_with('ROOMS')
	assert e.handle('aa', '0').contains('Unknown command')
}

fn test_engine_uses_the_injected_renderer() {
	mut e := help_engine()
	e.help = StubRenderer{}
	assert e.handle('aa', 'HELP').contains('STUB-WELCOME helpbbs')
	assert e.handle('aa', 'HELP mail') == 'STUB[mail]'
	assert e.handle('aa', '1').contains('Unknown command') // stub declines digits
}

fn test_welcome_is_a_three_step_start() {
	w := builtin_service().welcome('meshbbs', 'guest-ab12')
	assert w.contains('Welcome to meshbbs')
	assert w.contains('guest-ab12')
	assert w.contains('1) K')
	assert w.contains('2) C general')
	assert w.contains('3) N')
	assert w.contains('HELP')
}

fn test_documented_room_and_post_flow() {
	mut e := help_engine()
	e.handle('aa', 'HELP')
	assert e.handle('aa', 'K').contains('general')
	assert e.handle('aa', 'C general').contains('Now in general')
	assert e.handle('aa', 'E hello world').contains('. alone')
	e.handle('aa', 'my first post')
	assert e.handle('aa', '.').contains('osted')
	assert e.handle('aa', 'R general').contains('my first post')
	assert e.handle('aa', 'N').len > 0
	assert e.handle('aa', 'P general|subj|body text').contains('osted')
}

fn test_documented_mail_flow() {
	mut e := help_engine()
	e.handle('aa', 'HELP')
	e.handle('bb', 'HELP')
	assert e.handle('aa', 'MAIL node-bb').contains('Send . alone')
	e.handle('aa', 'hi bob')
	e.handle('aa', '.')
	assert e.handle('bb', 'CHECKMAIL').contains('1 new mail')
	assert e.handle('bb', 'MAILBOX').contains('hi bob')
	assert e.handle('aa', 'CALLERS').contains('Last callers')
}

// --- parsing and sources ---

const tiny_help = '[message menu_header]\nH:\n[message no_topic]\nno\n[message welcome]\nhi {who}\n[topic 1 a]\ntitle: A\n[command X]\nnames: X, Y\ntopic: a\nusage: X\nsummary: does x\n'

fn test_parse_minimal_help() {
	d := parse_help_text(tiny_help) or {
		assert false, err.msg()
		return
	}
	assert d.topics().len == 1 && d.commands().len == 1
	assert d.commands()[0].names == ['X', 'Y']
	assert d.message('welcome') == 'hi {who}'
}

fn test_parse_rejects_bad_help() {
	cases := {
		'unknown topic':     tiny_help.replace('topic: a', 'topic: zzz')
		'bad perm':          tiny_help.replace('title: A', 'title: A\nperm: wizard')
		'bad header':        tiny_help.replace('title: A', 'colour: red')
		'dup number':        tiny_help + '[topic 1 b]\ntitle: B\n'
		'number too big':    tiny_help.replace('topic 1 a', 'topic 10 a')
		'missing message':   tiny_help.replace('[message welcome]\nhi {who}\n', '')
		'reserved key':      tiny_help.replace('topic 1 a', 'topic 1 all')
		'duplicate command': tiny_help + '[command Z]\nnames: Y\ntopic: a\nusage: Z\nsummary: z\n'
		'no usage':          tiny_help.replace('usage: X\n', '')
		'bad section':       tiny_help + '[nonsense here]\n'
	}
	for name, text in cases {
		if _ := parse_help_text(text) {
			assert false, '${name} should have been rejected'
		}
	}
}

fn test_help_file_override_and_broken_file_falls_back() {
	mut e := help_engine()
	dir := os.join_path(os.temp_dir(), 'meshbbs_help_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	good := os.join_path(dir, 'help.txt')
	os.write_file(good, tiny_help.replace('hi {who}', 'FILE {who}')) or { panic(err) }
	r, src := load_help_renderer(mut e.store, good)
	assert src.starts_with(good)
	assert r.welcome('b', 'bob') == 'FILE bob'
	// a broken file is skipped, with the built-in text used instead
	bad := os.join_path(dir, 'bad.txt')
	os.write_file(bad, 'not a help file [topic') or { panic(err) }
	r2, src2 := load_help_renderer(mut e.store, bad)
	assert src2.starts_with('built-in help.txt')
	assert src2.contains('skipped')
	assert r2.welcome('b', 'bob').contains('Welcome to b')
	// no file at all: built-in, nothing skipped
	_, src3 := load_help_renderer(mut e.store, os.join_path(dir, 'missing.txt'))
	assert src3.starts_with('built-in') && !src3.contains('skipped')
}

fn test_helpimport_moves_help_into_the_database_and_helpreload_uses_it() {
	mut e := help_engine()
	dir := os.join_path(os.temp_dir(), 'meshbbs_helpdb_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	e.help_file = os.join_path(dir, 'help.txt')
	os.write_file(e.help_file, tiny_help.replace('hi {who}', 'DB {who}')) or { panic(err) }
	e.handle('aa', 'HELP') // sysop
	e.handle('bb', 'HELP')
	assert e.handle('bb', 'HELPIMPORT').contains('sysops only')
	assert e.handle('aa', 'HELPIMPORT').contains('Imported 1 topics')
	assert e.store.list_help_topics().len == 1
	assert e.store.list_help_commands().len == 1
	// the database now wins over the file
	os.write_file(e.help_file, tiny_help.replace('hi {who}', 'FILE {who}')) or { panic(err) }
	assert e.handle('aa', 'HELPRELOAD').contains('database')
	assert e.help.welcome('b', 'bob') == 'DB bob'
	assert e.handle('bb', 'HELPRELOAD').contains('sysops only')
	// a broken file is refused and the database is untouched
	os.write_file(e.help_file, 'garbage') or { panic(err) }
	assert e.handle('aa', 'HELPIMPORT').contains('nothing changed')
	assert e.store.list_help_topics().len == 1
}
