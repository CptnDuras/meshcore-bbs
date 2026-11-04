module main

// Email groups (sysop only): see email_groups.v.

fn register_email_commands(mut r CommandRegistry) {
	r.add(['GROUPS'], cmd_groups)
	r.add(['GROUP'], cmd_group)
	r.add(['GSEND'], cmd_gsend)
	r.add(['EMAILSTATUS', 'EMAILS'], cmd_emailstatus)
}

fn cmd_groups(mut e Engine, mut sess Session, args string) string {
	if _ := e.email_admin(sess) {
	} else {
		return email_admin_denied
	}
	return e.groups_overview()
}

fn cmd_group(mut e Engine, mut sess Session, args string) string {
	return e.group_command(mut sess, args)
}

fn cmd_gsend(mut e Engine, mut sess Session, args string) string {
	return e.gsend_start(mut sess, args)
}

fn cmd_emailstatus(mut e Engine, mut sess Session, args string) string {
	return e.email_status(sess)
}
