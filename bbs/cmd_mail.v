module main

// Private mail and quick notes.

fn register_mail_commands(mut r CommandRegistry) {
	r.add(['MAIL'], cmd_mail)
	r.add(['MAILBOX', 'INBOX'], cmd_mailbox)
	r.add(['CHECKMAIL', '/CHECKMAIL', 'CM'], cmd_checkmail)
	r.add(['THREAD'], cmd_thread)
	r.add(['TELL', 'T'], cmd_tell)
}

fn cmd_mail(mut e Engine, mut sess Session, args string) string {
	return e.start_mail(mut sess, args)
}

fn cmd_mailbox(mut e Engine, mut sess Session, args string) string {
	return e.read_mail(mut sess)
}

fn cmd_checkmail(mut e Engine, mut sess Session, args string) string {
	return e.check_mail(mut sess)
}

fn cmd_thread(mut e Engine, mut sess Session, args string) string {
	return e.thread_view(mut sess, args)
}

fn cmd_tell(mut e Engine, mut sess Session, args string) string {
	return e.tell(mut sess, args)
}
