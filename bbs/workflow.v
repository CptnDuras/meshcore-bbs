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
fn (mut e Engine) start_mail(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN to send mail.' }
	if !has_permission(user, 'mail') {
		return 'You are not verified yet; you cannot send mail.'
	}
	recipient := args.trim_space()
	if recipient.len == 0 {
		return 'Usage: MAIL <user>'
	}
	e.store.get_user(recipient) or { return 'No such user: ${recipient}' }
	sess.entry_mode = 'mail'
	sess.entry_buffer = ''
	sess.mail_to = recipient
	sess.state = state_entry
	return 'Enter mail to ${recipient}. Send . alone to finish.'
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
