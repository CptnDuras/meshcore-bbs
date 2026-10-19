module main

// Help is tested through its interfaces: a fake catalog and a fake viewer prove
// HelpService has no hidden dependencies, and a stub renderer proves the Engine
// takes its help from whatever it is given.

struct FakeCatalog {
	list []HelpTopic
}

fn (c FakeCatalog) topics() []HelpTopic {
	return c.list
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

fn two_topic_service() HelpService {
	return new_help_service(FakeCatalog{
		list: [
			HelpTopic{
				num:     1
				key:     'cats'
				title:   'Cats'
				aliases: ['kitty']
				body:    'meow'
			},
			HelpTopic{
				num:      2
				key:      'secret'
				title:    'Secret'
				body:     'sysop only'
				min_perm: .sysop
			},
		]
	})
}

fn test_service_uses_only_the_injected_catalog() {
	s := two_topic_service()
	v := FakeViewer{
		level: .user
	}
	assert s.render('', v) == 'HELP - reply with a number:\n1 Cats'
	assert s.render('1', v) == 'meow'
	assert s.render('cats', v) == 'meow'
	assert s.render('KITTY', v) == 'meow'
	assert s.render('nope', v).starts_with('No help topic "nope".')
}

fn test_topics_are_gated_by_permission() {
	s := two_topic_service()
	user := FakeViewer{
		level: .user
	}
	sysop := FakeViewer{
		level: .sysop
	}
	assert !s.render('', user).contains('Secret')
	assert s.render('secret', user).starts_with('No help topic')
	assert s.render('', sysop).contains('2 Secret')
	assert s.render('secret', sysop) == 'sysop only'
}

fn test_digit_shortcut() {
	s := two_topic_service()
	v := FakeViewer{
		level: .user
	}
	assert (s.topic_for_digit('1', v) or { '' }) == 'meow'
	if _ := s.topic_for_digit('2', v) {
		assert false, 'hidden topic must not open'
	}
	if _ := s.topic_for_digit('0', v) {
		assert false
	}
	if _ := s.topic_for_digit('12', v) {
		assert false
	}
	if _ := s.topic_for_digit('x', v) {
		assert false
	}
}

fn test_builtin_help_fits_one_radio_message_per_topic() {
	s := new_help_service(StaticHelpCatalog{})
	v := FakeViewer{
		level: .sysop
	}
	assert s.render('', v).len <= msg_max
	for t in StaticHelpCatalog{}.topics() {
		// the all-commands reference may span messages; every other screen is one
		if t.key != 'all' {
			assert t.body.len <= msg_max, '${t.key} is ${t.body.len} bytes'
		}
		assert t.body.contains('\n'), '${t.key} should be a short screen'
	}
}

fn test_builtin_menu_numbers_match_topics() {
	s := new_help_service(StaticHelpCatalog{})
	user := FakeViewer{
		level: .user
	}
	menu := s.render('', user)
	for n in 1 .. 7 {
		assert menu.contains('\n${n} ')
	}
	assert !menu.contains('\n7 ')
	assert !menu.contains('Sysop')
	aide := s.render('', FakeViewer{
		level: .aide
	})
	assert aide.contains('\n7 Moderation')
	assert !aide.contains('\n8 ')
}

fn test_engine_help_and_digit_flow() {
	mut e := help_engine()
	e.handle('aa', 'HELP') // first account is the sysop
	menu := e.handle('aa', 'HELP')
	assert menu.starts_with('HELP - reply with a number:')
	assert menu.contains('\n8 Sysop') // sysop sees admin topics
	assert e.handle('aa', '1').starts_with('ROOMS & POSTS')
	assert e.handle('aa', 'HELP mail').starts_with('MAIL & PEOPLE')
	assert e.handle('aa', 'HELP 3').contains('WX = now')
	// an ordinary user does not see (or open) admin topics
	e.handle('bb', 'HELP')
	assert !e.handle('bb', 'HELP').contains('Sysop')
	assert e.handle('bb', 'HELP sysop').starts_with('No help topic')
	assert e.handle('bb', '8').contains('Unknown command')
}

fn test_digits_do_not_break_other_commands() {
	mut e := help_engine()
	e.handle('aa', 'HELP')
	// VOTE with arguments still goes to voting, a number with args is not help
	assert !e.handle('aa', 'VOTE 1 2').starts_with('ROOMS')
	assert e.handle('aa', '9').contains('Unknown command')
}

fn test_engine_uses_the_injected_renderer() {
	mut e := help_engine()
	e.help = StubRenderer{}
	assert e.handle('aa', 'HELP').contains('STUB-WELCOME helpbbs')
	assert e.handle('aa', 'HELP mail') == 'STUB[mail]'
	assert e.handle('aa', '1').contains('Unknown command') // stub declines digits
}

fn test_welcome_is_a_three_step_start() {
	s := new_help_service(StaticHelpCatalog{})
	w := s.welcome('meshbbs', 'guest-ab12')
	assert w.contains('Welcome to meshbbs')
	assert w.contains('guest-ab12')
	assert w.contains('1) K')
	assert w.contains('2) C general')
	assert w.contains('3) R')
	assert w.contains('HELP')
}
