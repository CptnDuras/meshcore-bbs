module main

// Core commands: help, menu and BBS info.

fn register_core_commands(mut r CommandRegistry) {
	r.add(['HELP', '?'], cmd_help)
	r.add(['MENU', 'M'], cmd_menu)
	r.add(['WHO', 'W'], cmd_who)
	r.add(['STATS'], cmd_stats)
}

fn cmd_help(mut e Engine, mut sess Session, args string) string {
	return e.help_reply(sess, args)
}

fn cmd_menu(mut e Engine, mut sess Session, args string) string {
	return e.menu(sess)
}

fn cmd_who(mut e Engine, mut sess Session, args string) string {
	return e.who()
}

fn cmd_stats(mut e Engine, mut sess Session, args string) string {
	return e.stats()
}
