module main

// Your account, profile and the people directory.

fn register_account_commands(mut r CommandRegistry) {
	r.add(['REGISTER'], cmd_register)
	r.add(['CLAIM'], cmd_claim)
	r.add(['LOGIN'], cmd_login)
	r.add(['LOGOUT', 'Q'], cmd_logout)
	r.add(['SETPASS'], cmd_setpass)
	r.add(['SETBIO'], cmd_setbio)
	r.add(['CONFIG', '/CONFIG'], cmd_config)
	r.add(['LASTCALLERS', 'CALLERS'], cmd_callers)
	r.add(['PROFILE'], cmd_profile)
}

fn cmd_register(mut e Engine, mut sess Session, args string) string {
	return e.register(mut sess, args)
}

fn cmd_claim(mut e Engine, mut sess Session, args string) string {
	return e.claim(mut sess, args)
}

fn cmd_login(mut e Engine, mut sess Session, args string) string {
	return e.login(mut sess, args)
}

fn cmd_logout(mut e Engine, mut sess Session, args string) string {
	return e.logout(mut sess)
}

fn cmd_setpass(mut e Engine, mut sess Session, args string) string {
	return e.set_pass(mut sess, args)
}

fn cmd_setbio(mut e Engine, mut sess Session, args string) string {
	return e.set_bio(mut sess, args)
}

fn cmd_config(mut e Engine, mut sess Session, args string) string {
	return e.config(mut sess, args)
}

fn cmd_callers(mut e Engine, mut sess Session, args string) string {
	return e.last_callers()
}

fn cmd_profile(mut e Engine, mut sess Session, args string) string {
	return e.profile(args)
}
