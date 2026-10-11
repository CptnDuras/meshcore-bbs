module main

// Message-entry workflow (Spec 12) + Mail (Spec 13).
// While a session is in entry mode, each inbound line is appended to the
// buffer until a line containing only '.' finalizes the message.

// in_entry reports whether the session is mid message-entry.
fn (e Engine) in_entry(sess Session) bool {
	return sess.entry_mode.len > 0
}

// handle_entry_line accumulates a line during entry; '.' alone finalizes.
fn (mut e Engine) handle_entry_line(mut sess Session, line string) string {
	if line.trim_space() == '.' {
		return e.finalize_entry(mut sess)
	}
	if sess.entry_buffer.len > 0 {
		sess.entry_buffer += '\n' + line
	} else {
		sess.entry_buffer = line
	}
	return '(entry: send more, or . alone to finish)'
}

fn (mut e Engine) finalize_entry(mut sess Session) string {
	mode := sess.entry_mode
	body := sess.entry_buffer
	subject := sess.entry_subject
	recipient := sess.mail_to
	// clear entry state
	sess.entry_mode = ''
	sess.entry_buffer = ''
	sess.entry_subject = ''
	sess.mail_to = ''
	sess.state = state_main

	if body.trim_space().len == 0 {
		return 'Empty message discarded.'
	}
	if mode == 'mail' {
		e.store.send_mail(recipient, sess.handle, body) or { return 'Mail failed: ${err}' }
		return 'Mail sent to ${recipient}.'
	}
	// room post
	if sess.current_board == 0 {
		return 'No room selected; message discarded.'
	}
	e.store.post_message(sess.current_board, sess.handle, subject, body, 0) or {
		return 'Post failed: ${err}'
	}
	return 'Message posted.'
}

// start_entry begins entering a message in the current room (E command).
// Optional args become the subject.
fn (mut e Engine) start_entry(mut sess Session, subject string) string {
	user := e.current_user(sess) or { return 'You must LOGIN to enter a message.' }
	if !has_permission(user, 'enter') {
		return 'You are not verified yet; you cannot post.'
	}
	if sess.current_board == 0 {
		return 'Select a room first (C <room>).'
	}
	sess.entry_mode = 'post'
	sess.entry_buffer = ''
	sess.entry_subject = subject
	sess.state = state_entry
	return 'Enter your message. Send . alone on a line to finish.'
}

// start_mail begins entering a private message to <user> (MAIL command).
// You may MAIL any handle — if the recipient has no account yet, a mailbox is
// auto-created so the message can be stored for them. A leading '@' on the
// argument triggers partial-name resolution (see resolve_recipient).
fn (mut e Engine) start_mail(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN to send mail.' }
	if !has_permission(user, 'mail') {
		return 'You are not verified yet; you cannot send mail.'
	}
	arg := args.trim_space()
	if arg.len == 0 {
		return 'Usage: MAIL <user>'
	}
	recipient := if arg.starts_with('@') {
		e.resolve_recipient(arg[1..]) or { return err.msg() }
	} else {
		arg
	}
	// Mail-anyone: ensure a mailbox exists so the message can be stored even if
	// the recipient has never contacted the BBS.
	e.store.ensure_mailbox(recipient) or { return 'Mail failed: ${err}' }
	sess.entry_mode = 'mail'
	sess.entry_buffer = ''
	sess.mail_to = recipient
	sess.state = state_entry
	return 'Enter mail to ${recipient}. Send . alone to finish.'
}

// resolve_recipient resolves a partial name (from MAIL @<partial> / THREAD
// @<partial>). It matches REGISTERED USERS FIRST (real handles, not node-
// prefixed), then SEEN NODE names, case-insensitively by PREFIX. A single match
// returns that handle; multiple matches return an error listing candidates; no
// match returns a 'No match' error. Returns the resolved handle or an error
// whose message is the user-facing reply.
fn (mut e Engine) resolve_recipient(partial string) !string {
	p := partial.trim_space().to_lower()
	if p.len == 0 {
		return error('No match for @')
	}
	// Registered users first: real handles only (skip node- auto-handles).
	mut matches := []string{}
	for u in e.store.list_users() {
		if is_node_handle(u.handle) {
			continue
		}
		if u.handle.to_lower().starts_with(p) {
			matches << u.handle
		}
	}
	// Then seen node names (radio contact-list).
	for n in e.store.list_node_names(1000) {
		if n.name.len == 0 {
			continue
		}
		if n.name.to_lower().starts_with(p) && n.name !in matches {
			matches << n.name
		}
	}
	if matches.len == 0 {
		return error('No match for @${partial}')
	}
	if matches.len == 1 {
		return matches[0]
	}
	return error('Multiple: ${matches.join(', ')} - be more specific')
}

// thread_view shows the conversation-by-correspondent: ALL mail between the
// current user and <handle> in BOTH directions, oldest->newest. It is
// re-readable — it never marks mail read or deletes anything. A leading '@'
// triggers partial-name resolution.
fn (mut e Engine) thread_view(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN to read mail.' }
	arg := args.trim_space()
	if arg.len == 0 {
		return 'Usage: THREAD <user>'
	}
	other := if arg.starts_with('@') {
		e.resolve_recipient(arg[1..]) or { return err.msg() }
	} else {
		arg
	}
	mails := e.store.conversation(user.handle, other, 50)
	if mails.len == 0 {
		return 'No mail with ${other}.'
	}
	mut b := '== Thread: ${other} ==\n'
	for m in mails {
		dir := if m.from_handle == user.handle { '> to them' } else { '< from them' }
		b += '${dir}: ${m.body}\n'
	}
	return b
}

// read_mail shows the user's inbox and marks it read.
fn (mut e Engine) read_mail(mut sess Session) string {
	user := e.current_user(sess) or { return 'You must LOGIN to read mail.' }
	mails := e.store.list_mail(user.handle, 20)
	if mails.len == 0 {
		return 'No mail.'
	}
	mut b := '== Mail ==\n'
	for m in mails {
		flag := if m.is_read { ' ' } else { '*' }
		b += '${flag} from ${m.from_handle}: ${m.body}\n---\n'
	}
	e.store.mark_mail_read(user.handle) or {}
	return b
}

// mail_notice returns a new-mail notice string (empty if none).
fn (mut e Engine) mail_notice(handle string) string {
	if handle.len == 0 {
		return ''
	}
	n := e.store.unread_mail_count(handle)
	if n > 0 {
		return '\nYou have ${n} new mail. Send MAILBOX to read.'
	}
	return ''
}

// check_mail reports the unread mail count WITHOUT marking anything read
// (unlike MAILBOX/read_mail). Backs the CHECKMAIL / /CHECKMAIL command.
fn (mut e Engine) check_mail(mut sess Session) string {
	user := e.current_user(sess) or { return 'You must LOGIN to check mail.' }
	n := e.store.unread_mail_count(user.handle)
	total := e.store.list_mail(user.handle, 100).len
	if n == 0 {
		if total == 0 {
			return 'No mail.'
		}
		return 'No new mail (${total} in mailbox). MAILBOX to read.'
	}
	return 'You have ${n} new mail (${total} total). Send MAILBOX to read.'
}
