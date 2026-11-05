module emaillist

// The rules for the email groups' people, shared by the daemon (bbs/) and the web UI (webui/), which are separate programs: what counts as an address,
// how a pasted list is read, and the columns of the tables both sides use. (The same arrangement as mqttcfg.)

// A member is mailed while 'active'. 'unsubscribed' is set by the sysop at the person's request and is never undone by an import. 'rejected' is set
// when SES refuses the address (it is not verified, or it bounced); the sysop can look at it and put it back.
pub const member_active = 'active'
pub const member_unsubscribed = 'unsubscribed'
pub const member_rejected = 'rejected'

// The columns of the tables the daemon's ORM creates (bbs/email_models.v). The web UI writes to them with plain SQL, so it must know their names;
// bbs/email_store_test.v checks these lists against the real tables, and the web UI's tests build theirs from them.
pub const groups_columns = ['id', 'name', 'descr', 'created']
pub const members_columns = ['id', 'group_name', 'email', 'name', 'status', 'note', 'added', 'last_sent',
	'last_error']
pub const outbox_columns = ['id', 'to_addr', 'subject', 'body', 'group_name', 'created', 'status',
	'attempts', 'next_try', 'last_error', 'sent_ts', 'message_id', 'from_name', 'list_post']

// Mail people send to the list address (bbs/inbound_worker.v): the record of every message looked at, the senders the sysop has blocked, and a few
// switches. The web UI shows the first, edits the second and flips the third.
pub const inbound_columns = ['id', 's3_key', 'message_id', 'from_addr', 'from_name', 'subject',
	'received', 'status', 'reason', 'recipients']
pub const blocks_columns = ['id', 'pattern', 'note', 'added']
pub const settings_columns = ['id', 'key', 'val']

// what became of an incoming message
pub const inbound_posting = 'posting' // being passed on (stays this way if the daemon stopped half way)
pub const inbound_posted = 'posted' // passed on to the list
pub const inbound_stopped = 'stopped' // was a request to be taken off the list, and the sender was
pub const inbound_rejected = 'rejected' // turned away; `reason` says why
pub const inbound_failed = 'failed' // could not be read or fetched

// the switch that pauses posting by email
pub const setting_inbound_paused = 'inbound_paused'

// What the daemon tells the web UI about posting by email, so the page can show it without reading the settings file (which holds the AWS key).
pub const setting_inbound_address = 'inbound_address' // the list address; empty when posting by email is not set up
pub const setting_inbound_group = 'inbound_group'
pub const setting_inbound_poll = 'inbound_poll' // when the mailbox was last looked in (epoch seconds)
pub const setting_inbound_error = 'inbound_error' // what went wrong the last time, or empty

// A pattern for the block list: one address, or "@domain.example" for everyone at a domain.
pub fn valid_block_pattern(p string) bool {
	if p.contains('*') {
		return false // no wildcards: a pattern that looks like one would match nothing and block no one
	}
	if p.starts_with('@') {
		d := p[1..]
		return d.len >= 3 && d.len <= 253 && d.contains('.') && !d.starts_with('.') && !d.ends_with('.') && !d.contains('..')
			&& d.bytes().all(it.is_alnum() || it == `.` || it == `-`)
	}
	return valid_email(p)
}

// no control characters in a value: a newline in anything bound for a mail header could start a second header
pub fn plain_value(v string) bool {
	return v.bytes().all(it >= 32 && it != 127)
}

pub fn normalize_email(s string) string {
	return s.trim_space().to_lower()
}

// A deliberately plain check: one @, something before it, a dotted domain after it, no spaces, quotes, angle brackets, commas or control characters.
// It is there to keep rubbish and header tricks out of the list, not to prove the mailbox exists (SES does that when it tries).
pub fn valid_email(a string) bool {
	if a.len < 6 || a.len > 254 || a.count('@') != 1 || !plain_value(a) {
		return false
	}
	if a.bytes().any(it in [` `, `"`, `<`, `>`, `,`, `;`, `(`, `)`, `\\`, `'`]) {
		return false
	}
	local := a.all_before('@')
	domain := a.all_after('@')
	return local.len > 0 && local.len <= 64 && domain.contains('.') && !domain.starts_with('.') && !domain.ends_with('.') && !domain.contains('..')
		&& domain.bytes().all(it.is_alnum() || it == `.` || it == `-`)
}

// Group names are what the sysop types, and what a scheduled message names as its target.
pub fn valid_group_name(n string) bool {
	return n.len >= 2 && n.len <= 24 && n.bytes().all(it.is_alnum() || it == `-` || it == `_`)
}

// a display name is plain text of a sensible length, with nothing in it that could start a header or a tag
pub fn clean_name(s string) string {
	t := s.trim_space().replace('"', '').replace('<', '').replace('>', '').replace('\r', ' ').replace('\n', ' ')
	r := t.runes()
	return (if r.len > 60 { r[..60].string() } else { t }).trim_space()
}

pub struct MemberEntry {
pub:
	email string
	name  string
}

// One person from one line of a list. Accepts "ada@example.com", "ada@example.com Ada Lovelace", "ada@example.com, Ada Lovelace", "Ada Lovelace <ada@example.com>"
// and the same with a tab between. none for a blank line, a comment, or a line with no usable address.
pub fn parse_member_line(raw string) ?MemberEntry {
	line := raw.trim_space()
	if line == '' || line.starts_with('#') {
		return none
	}
	fields := line.replace('\t', ',').replace(';', ',').split(',').map(it.trim_space()).filter(it != '')
	if fields.len == 0 {
		return none
	}
	// "ada@example.com Ada Lovelace" with spaces only
	first := fields[0].split(' ')[0]
	if valid_email(normalize_email(first)) {
		rest := fields[0].all_after(first).trim_space()
		extra := if fields.len > 1 { fields[1..].join(' ') } else { '' }
		return MemberEntry{
			email: normalize_email(first)
			name:  clean_name('${rest} ${extra}')
		}
	}
	// "Ada Lovelace <ada@example.com>"
	if line.contains('<') && line.contains('>') {
		email := normalize_email(line.all_after('<').all_before('>'))
		if valid_email(email) {
			return MemberEntry{
				email: email
				name:  clean_name(line.all_before('<'))
			}
		}
		return none
	}
	// "Ada Lovelace, ada@example.com"
	for f in fields {
		if valid_email(normalize_email(f)) {
			others := fields.filter(it != f)
			return MemberEntry{
				email: normalize_email(f)
				name:  clean_name(others.join(' '))
			}
		}
	}
	return none
}

pub struct ParsedList {
pub:
	people []MemberEntry
	bad    []string // the lines that had text but no usable address
}

pub fn parse_member_list(text string) ParsedList {
	mut people := []MemberEntry{}
	mut bad := []string{}
	mut seen := map[string]bool{}
	for raw in text.split('\n') {
		line := raw.trim_space()
		if line == '' || line.starts_with('#') {
			continue
		}
		if p := parse_member_line(line) {
			if p.email !in seen {
				seen[p.email] = true
				people << p
			}
		} else {
			bad << line
		}
	}
	return ParsedList{
		people: people
		bad:    bad
	}
}
