module main

// Moderator and sysop commands. Each handler enforces its own permission.

fn register_admin_commands(mut r CommandRegistry) {
	r.add(['VERIFY'], cmd_verify)
	r.add(['PROMOTE'], cmd_promote)
	r.add(['DEMOTE'], cmd_demote)
	r.add(['TWIT'], cmd_twit)
	r.add(['BAN'], cmd_ban)
	r.add(['UNBAN'], cmd_unban)
	r.add(['DELETE', 'DEL'], cmd_delete)
	r.add(['BULLET'], cmd_bullet)
	r.add(['ALERTTEST'], cmd_alerttest)
	r.add(['HELPRELOAD'], cmd_helpreload)
	r.add(['HELPIMPORT'], cmd_helpimport)
}

fn cmd_verify(mut e Engine, mut sess Session, args string) string {
	return e.verify_user(mut sess, args)
}

fn cmd_promote(mut e Engine, mut sess Session, args string) string {
	return e.set_perm_cmd(mut sess, args, .aide)
}

fn cmd_demote(mut e Engine, mut sess Session, args string) string {
	return e.set_perm_cmd(mut sess, args, .user)
}

fn cmd_twit(mut e Engine, mut sess Session, args string) string {
	return e.set_perm_cmd(mut sess, args, .twit)
}

fn cmd_ban(mut e Engine, mut sess Session, args string) string {
	return e.ban_user(mut sess, args, true)
}

fn cmd_unban(mut e Engine, mut sess Session, args string) string {
	return e.ban_user(mut sess, args, false)
}

fn cmd_delete(mut e Engine, mut sess Session, args string) string {
	return e.delete_message(mut sess, args)
}

fn cmd_bullet(mut e Engine, mut sess Session, args string) string {
	return e.post_bulletin(mut sess, args)
}

fn cmd_alerttest(mut e Engine, mut sess Session, args string) string {
	return e.alert_test(sess, args)
}

// HELPRELOAD re-reads the help text from its current source (database, then
// help.txt, then the built-in file) without a restart.
fn cmd_helpreload(mut e Engine, mut sess Session, args string) string {
	if !e.is_sysop(sess) {
		return 'HELPRELOAD is for sysops only.'
	}
	r, source := load_help_renderer(mut e.store, e.help_file)
	e.help = r
	return 'Help reloaded from ${source}.'
}

// HELPIMPORT copies the help file into the database, so help can be kept there.
fn cmd_helpimport(mut e Engine, mut sess Session, args string) string {
	if !e.is_sysop(sess) {
		return 'HELPIMPORT is for sysops only.'
	}
	n := import_help_into_store(mut e.store, e.help_file) or {
		return 'Import failed (nothing changed): ${err.msg()}'
	}
	r, source := load_help_renderer(mut e.store, e.help_file)
	e.help = r
	return 'Imported ${n} topics from ${e.help_file} into the database. Help now comes from ${source}.'
}
