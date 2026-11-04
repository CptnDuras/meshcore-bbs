module main

import time

// Email groups: the sysop's commands (GROUPS, GROUP, GSEND, EMAILSTATUS) and the fan-out that turns one notice into one queued email per member.
// Everything that sends is in email_worker.v; everything that talks to SES is in ses.v.

// ---- pure helpers ----

fn normalize_email(s string) string {
	return s.trim_space().to_lower()
}

// Group names are what the sysop types, and what a scheduled message names as its target.
fn valid_group_name(n string) bool {
	return n.len >= 2 && n.len <= 24 && n.bytes().all(it.is_alnum() || it == `-` || it == `_`)
}

struct MemberEntry {
pub:
	email string
	name  string
}

// One person from one line of a list. Accepts "ada@example.com", "ada@example.com Ada Lovelace", "ada@example.com, Ada Lovelace", "Ada Lovelace <ada@example.com>"
// and the same with a tab between. none for a blank line, a comment, or a line with no usable address.
fn parse_member_line(raw string) ?MemberEntry {
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

// a display name is plain text of a sensible length, with nothing in it that could start a header or a tag
fn clean_name(s string) string {
	t := s.trim_space().replace('"', '').replace('<', '').replace('>', '').replace('\r', ' ').replace('\n', ' ')
	r := t.runes()
	return (if r.len > 60 { r[..60].string() } else { t }).trim_space()
}

struct ParsedList {
pub:
	people []MemberEntry
	bad    []string // the lines that had text but no usable address
}

fn parse_member_list(text string) ParsedList {
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

// the first line of a message, shortened, as its subject
fn subject_from_text(text string, fallback string) string {
	first := text.trim_space().split('\n')[0].trim_space()
	if first == '' {
		return fallback
	}
	r := first.runes()
	return if r.len > 70 { r[..70].string() + '...' } else { first }
}

const email_body_limit = 5000

// What the person reads: the notice, then a plain footer saying who sent it, why they got it and how to stop. There is no link: replies go to the
// sysop (the Reply-To in the SES settings), who takes the person off.
fn compose_email_body(bbs_name string, group string, name string, text string) string {
	hello := if name != '' { 'Hello ${name},\n\n' } else { '' }
	body := if text.runes().len > email_body_limit {
		text.runes()[..email_body_limit].string() + '\n[cut]'
	} else {
		text
	}
	return '${hello}${body.trim_space()}\n\n--\nYou are getting this because you asked to be on the ${group} list of ${bbs_name}, a volunteer radio mesh.\nTo stop, reply to this email and say STOP.\n'
}

// ---- the engine ----

// One queued email for each active member of the group. -> how many were queued.
fn (mut e Engine) email_fanout(group string, subject string, text string, now i64) !int {
	if _ := e.store.get_email_group(group) {
	} else {
		return error('no email group called ${group}')
	}
	mut n := 0
	for m in e.store.list_email_members(group) {
		if m.status != member_active {
			continue
		}
		e.store.enqueue_email(m.email, one_line_subject(subject), compose_email_body(e.name, group, m.name, text), group, now)!
		n++
	}
	return n
}

// The outbound queue's email targets: a scheduled digest or alert whose target is an email group. '' on success, else what went wrong (logged by the loop).
fn (mut e Engine) email_outbound(om OutboundMessage, now i64) string {
	subject := subject_from_text(om.text, 'News from ${e.name}')
	n := e.email_fanout(om.target, subject, om.text, now) or { return err.msg() }
	if n == 0 {
		return 'email group ${om.target} has no active members'
	}
	return ''
}

fn (mut e Engine) email_admin(sess Session) ?User {
	u := e.current_user(sess) or { return none }
	if !has_permission(u, 'email_admin') {
		return none
	}
	return u
}

const email_admin_denied = 'Only the sysop can manage email groups.'

fn (mut e Engine) groups_overview() string {
	groups := e.store.list_email_groups()
	if groups.len == 0 {
		return 'No email groups. GROUP NEW <name> makes one.'
	}
	mut b := '== Email groups ==\n'
	for g in groups {
		ms := e.store.list_email_members(g.name)
		active := ms.filter(it.status == member_active).len
		b += '${g.name}: ${active} active of ${ms.len}${if g.descr != '' {
			' - ' + g.descr
		} else {
			''
		}}\n'
	}
	return b.trim_right('\n')
}

fn (mut e Engine) group_command(mut sess Session, args string) string {
	if _ := e.email_admin(sess) {
	} else {
		return email_admin_denied
	}
	parts := args.trim_space().split(' ').filter(it != '')
	usage := 'GROUP NEW <name> [about] | GROUP DROP <name> | GROUP <name> LIST|ADD <email> [name]|DEL <email>|STOP <email>|START <email>'
	if parts.len == 0 {
		return usage
	}
	now := time.now().unix()
	first := parts[0].to_upper()
	if first == 'NEW' {
		if parts.len < 2 || !valid_group_name(parts[1].to_lower()) {
			return 'Group names are 2-24 letters, digits, - or _. Usage: GROUP NEW <name> [about]'
		}
		name := parts[1].to_lower()
		made := e.store.ensure_email_group(name, parts[2..].join(' '), now) or { return 'Failed: ${err}' }
		return if made {
			'Group ${name} created. GROUP ${name} ADD <email> to add people.'
		} else {
			'Group ${name} already exists.'
		}
	}
	if first == 'DROP' {
		if parts.len < 2 {
			return 'Usage: GROUP DROP <name>'
		}
		name := parts[1].to_lower()
		e.store.get_email_group(name) or { return 'No group ${name}.' }
		e.store.delete_email_group(name) or { return 'Failed: ${err}' }
		return 'Group ${name} and its member list removed.'
	}
	name := parts[0].to_lower()
	e.store.get_email_group(name) or { return 'No group ${name}. GROUPS lists them.' }
	if parts.len < 2 {
		return usage
	}
	action := parts[1].to_upper()
	match action {
		'LIST' {
			ms := e.store.list_email_members(name)
			if ms.len == 0 {
				return 'Group ${name} is empty.'
			}
			mut b := '== ${name}: ${ms.len} ==\n'
			for m in ms {
				b += '${m.email}${if m.name != '' { ' (' + m.name + ')' } else { '' }} ${if m.status == member_active {
					''
				} else {
					'[' + m.status + ']'
				}}\n'
			}
			return b.trim_right('\n')
		}
		'ADD' {
			if parts.len < 3 {
				return 'Usage: GROUP ${name} ADD <email> [name]'
			}
			email := normalize_email(parts[2])
			if !valid_email(email) {
				return '${parts[2]} does not look like an email address.'
			}
			added := e.store.add_email_member(name, email, clean_name(parts[3..].join(' ')), 'added by ${sess.handle}', now) or { return 'Failed: ${err}' }
			return if added {
				'Added ${email} to ${name}.'
			} else {
				'${email} is already in ${name}.'
			}
		}
		'DEL', 'STOP', 'START' {
			if parts.len < 3 {
				return 'Usage: GROUP ${name} ${action} <email>'
			}
			email := normalize_email(parts[2])
			m := e.store.get_email_member(name, email) or { return '${email} is not in ${name}.' }
			if action == 'DEL' {
				e.store.remove_email_member(name, email) or { return 'Failed: ${err}' }
				return 'Removed ${email} from ${name}.'
			}
			status := if action == 'STOP' { member_unsubscribed } else { member_active }
			e.store.set_email_member_status(name, m.email, status, '') or { return 'Failed: ${err}' }
			return if action == 'STOP' {
				'${email} will get no more email from ${name}.'
			} else {
				'${email} is back on ${name}.'
			}
		}
		else {
			return usage
		}
	}
}

// GSEND <group> [subject]: then the message, ended by a line with only a dot, like MAIL.
fn (mut e Engine) gsend_start(mut sess Session, args string) string {
	if _ := e.email_admin(sess) {
	} else {
		return email_admin_denied
	}
	parts := args.trim_space().split(' ').filter(it != '')
	if parts.len == 0 {
		return 'Usage: GSEND <group> [subject]'
	}
	group := parts[0].to_lower()
	g := e.store.get_email_group(group) or { return 'No group ${group}. GROUPS lists them.' }
	sess.entry_mode = 'gsend'
	sess.entry_buffer = ''
	sess.entry_subject = parts[1..].join(' ')
	sess.mail_to = g.name
	sess.state = state_entry
	return 'Enter the message for ${g.name}. Send . alone on a line to finish.'
}

fn (mut e Engine) gsend_finish(group string, subject string, body string) string {
	now := time.now().unix()
	subj := if subject.trim_space() != '' {
		subject
	} else {
		subject_from_text(body, 'A message from ${e.name}')
	}
	n := e.email_fanout(group, subj, body, now) or { return 'Not sent: ${err}' }
	if n == 0 {
		return 'Group ${group} has no active members; nothing queued.'
	}
	return 'Queued ${n} email${if n == 1 { '' } else { 's' }} to ${group}. EMAILSTATUS shows progress.'
}

fn (mut e Engine) email_status(sess Session) string {
	if _ := e.email_admin(sess) {
	} else {
		return email_admin_denied
	}
	now := time.now().unix()
	mut b := '== Email ==\n'
	b += 'queued ${e.store.count_emails(email_queued)}, sent ${e.store.count_emails(email_sent)}, failed ${e.store.count_emails(email_failed)}\n'
	b += 'sent in the last 24h: ${e.store.count_emails_sent_since(now - 86400)}\n'
	for f in e.store.recent_failed_emails(3) {
		b += 'failed: ${f.to_addr}: ${f.last_error}\n'
	}
	return b.trim_right('\n')
}
