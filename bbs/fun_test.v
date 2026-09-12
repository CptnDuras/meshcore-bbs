module main

fn fun_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store: store
		name:  'funbbs'
	}
}

// --- parse_dice ---

fn test_parse_dice_default() {
	n, s := parse_dice('') or { panic('should default') }
	assert n == 1
	assert s == 6
}

fn test_parse_dice_ndm() {
	n, s := parse_dice('2d6') or { panic('valid') }
	assert n == 2
	assert s == 6
}

fn test_parse_dice_bare_d() {
	n, s := parse_dice('d20') or { panic('valid') }
	assert n == 1
	assert s == 20
}

fn test_parse_dice_bare_number() {
	n, s := parse_dice('20') or { panic('valid') }
	assert n == 1
	assert s == 20
}

fn test_parse_dice_rejects_out_of_range() {
	if _, _ := parse_dice('0d6') {
		assert false, 'zero dice should be rejected'
	}
	if _, _ := parse_dice('99d6') {
		assert false, 'too many dice should be rejected'
	}
	if _, _ := parse_dice('2d1') {
		assert false, 'one-sided die should be rejected'
	}
}

// --- parse_fortunes ---

fn test_parse_fortunes_skips_blanks_and_comments() {
	content := 'First fortune\n\n# a comment\n  Second fortune  \n'
	got := parse_fortunes(content)
	assert got.len == 2
	assert got[0] == 'First fortune'
	assert got[1] == 'Second fortune'
}

fn test_parse_fortunes_empty() {
	assert parse_fortunes('').len == 0
	assert parse_fortunes('# only a comment\n').len == 0
}

// --- command wiring (results are random but must be well-formed) ---

fn test_roll_command_single() {
	mut e := fun_engine()
	r := e.handle('aa', 'ROLL d6')
	assert r.contains('Rolled d6:')
}

fn test_roll_command_multi() {
	mut e := fun_engine()
	r := e.handle('aa', 'ROLL 3d6')
	assert r.contains('Rolled 3d6:')
	assert r.contains('=')
}

fn test_roll_bad_spec() {
	mut e := fun_engine()
	r := e.handle('aa', 'ROLL garbage')
	assert r.contains('Usage')
}

fn test_fortune_command_nonempty() {
	mut e := fun_engine()
	r := e.handle('aa', 'FORTUNE')
	assert r.len > 0
	assert !r.contains('No fortunes')
}

fn test_8ball_needs_question() {
	mut e := fun_engine()
	r := e.handle('aa', '8BALL')
	assert r.contains('Ask the 8-ball')
}

fn test_8ball_answers() {
	mut e := fun_engine()
	r := e.handle('aa', '8BALL will it work?')
	assert r.contains('8-ball:')
}

fn test_joke_command() {
	mut e := fun_engine()
	r := e.handle('aa', 'JOKE')
	assert r.len > 0
}
