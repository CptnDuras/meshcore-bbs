module emaillist

// ---- addresses ----

fn test_ordinary_addresses_pass() {
	for a in ['a@b.co', 'first.last+tag@sub.example.org', 'x_y-z@example-mail.com'] {
		assert valid_email(a), a
	}
}

fn test_addresses_that_are_not_addresses_or_that_carry_tricks_fail() {
	for a in ['', 'plain', 'a@b', '@b.co', 'a@@b.co', 'a b@c.co', 'a@b.co,c@d.co', '<a@b.co>',
		'"a"@b.co', 'a@b.co\nBcc: x@y.z', 'a@.co', 'a@b..co', 'a@b.co.', 'a(c)@b.co', 'a@b_c.co'] {
		assert !valid_email(a), a
	}
}

fn test_values_with_control_characters_are_not_plain() {
	assert plain_value('Buffalo Mesh') && plain_value('café')
	assert !plain_value('a\nb') && !plain_value('a\rb') && !plain_value('a\x00b') && !plain_value('a\x7fb')
}

fn test_group_names() {
	for n in ['family', 'ham-club', 'a_b', 'x1', 'ab'] {
		assert valid_group_name(n), n
	}
	for n in ['', 'a', 'has space', 'a'.repeat(25), 'semi;colon', 'ünï'] {
		assert !valid_group_name(n), n
	}
}

// ---- reading a pasted list ----

fn test_each_common_way_of_writing_a_person_is_read() {
	cases := {
		'ada@example.com':                  ['ada@example.com', '']
		'  Ada@Example.COM  ':              ['ada@example.com', '']
		'ada@example.com Ada Lovelace':     ['ada@example.com', 'Ada Lovelace']
		'ada@example.com, Ada Lovelace':    ['ada@example.com', 'Ada Lovelace']
		'ada@example.com\tAda':             ['ada@example.com', 'Ada']
		'Ada Lovelace <ada@example.com>':   ['ada@example.com', 'Ada Lovelace']
		'"Ada Lovelace" <ada@example.com>': ['ada@example.com', 'Ada Lovelace']
		'Ada Lovelace, ada@example.com':    ['ada@example.com', 'Ada Lovelace']
	}
	for line, want in cases {
		p := parse_member_line(line) or { panic('not read: ${line}') }
		assert p.email == want[0], line
		assert p.name == want[1], line
	}
}

fn test_blank_lines_comments_and_lines_without_an_address_are_not_people() {
	for line in ['', '   ', '# a comment', 'just words', 'no-at-sign.example.com', '<>', 'a@b'] {
		assert parse_member_line(line) == none, line
	}
}

fn test_a_list_is_read_whole_with_duplicates_dropped_and_bad_lines_reported() {
	text := '# the family list\nada@example.com Ada\nbob@example.com\n\nADA@example.com again\nwhat is this\ncarol@example.org, Carol\n'
	got := parse_member_list(text)
	assert got.people.map(it.email) == ['ada@example.com', 'bob@example.com', 'carol@example.org']
	assert got.people[0].name == 'Ada'
	assert got.bad == ['what is this']
}

fn test_windows_line_endings_are_fine() {
	got := parse_member_list('ada@example.com Ada\r\nbob@example.com\r\n')
	assert got.people.map(it.email) == ['ada@example.com', 'bob@example.com']
	assert got.people[0].name == 'Ada' && got.bad.len == 0
}

fn test_a_name_cannot_carry_markup_or_a_line_break() {
	p := parse_member_line('x@example.com Eve"<b>\rBcc: y@z.co') or { panic('not read') }
	assert !p.name.contains('"') && !p.name.contains('<') && !p.name.contains('\r')
	assert clean_name('a'.repeat(100)).len == 60
}

fn test_a_block_is_an_address_or_a_whole_domain() {
	for p in ['spam@example.com', '@example.com', '@mail.example.co.uk', '@a-b.example.org'] {
		assert valid_block_pattern(p), p
	}
	for p in ['', '@', '@com', '@.example.com', '@example.com.', '@exa mple.com', '@ex..ample.com',
		'example.com', '*@example.com', 'a@b', '@example.com\nBcc: x', '@@example.com'] {
		assert !valid_block_pattern(p), p
	}
}

fn test_the_member_states_are_the_words_the_tables_hold() {
	assert [member_active, member_unsubscribed, member_rejected] == ['active', 'unsubscribed',
		'rejected']
}
