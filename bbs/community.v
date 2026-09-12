module main

// Community features (Spec 11 SHOULD tier): oneliners, bulletins, last-callers,
// TELL, user profiles.

// oneliner: with args, post a one-liner (verified users); without, show recent.
fn (mut e Engine) oneliner(mut sess Session, args string) string {
	if args.trim_space().len == 0 {
		lines := e.store.list_oneliners(10)
		if lines.len == 0 {
			return 'No oneliners yet. ONELINER <text> to add one.'
		}
		mut b := '== Oneliners ==\n'
		for o in lines {
			b += '- ${o.text} (${o.author})\n'
		}
		return b
	}
	user := e.current_user(sess) or { return 'You must LOGIN to post a oneliner.' }
	if !has_permission(user, 'oneliner_post') {
		return 'You are not verified yet.'
	}
	e.store.add_oneliner(user.handle, args.trim_space()) or { return 'Failed: ${err}' }
	return 'Oneliner posted!'
}

// bulletins: list current bulletins (all); posting is sysop-only via BULLET.
fn (mut e Engine) bulletins() string {
	bs := e.store.list_bulletins(10)
	if bs.len == 0 {
		return 'No bulletins.'
	}
	mut b := '== Bulletins ==\n'
	for bl in bs {
		b += '* ${bl.title}\n${bl.body}\n---\n'
	}
	return b
}

fn (mut e Engine) post_bulletin(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN.' }
	if !has_permission(user, 'bulletin_post') {
		return 'Permission denied (SYSOP required).'
	}
	parts := args.split('|')
	if parts.len < 2 {
		return 'Usage: BULLET <title>|<body>'
	}
	e.store.add_bulletin(parts[0].trim_space(), parts[1].trim_space()) or {
		return 'Failed: ${err}'
	}
	return 'Bulletin posted.'
}

// last_callers: recent users by last_seen.
fn (mut e Engine) last_callers() string {
	users := e.store.recent_users(10)
	if users.len == 0 {
		return 'No callers yet.'
	}
	mut b := '== Last callers ==\n'
	for u in users {
		b += '- ${u.handle}\n'
	}
	return b
}

// tell: async one-shot note to a user (delivered as mail).
fn (mut e Engine) tell(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN to use TELL.' }
	if !has_permission(user, 'tell') {
		return 'You are not verified yet.'
	}
	parts := args.split(' ')
	if parts.len < 2 {
		return 'Usage: TELL <user> <message>'
	}
	target := parts[0]
	msg := parts[1..].join(' ')
	e.store.get_user(target) or { return 'No such user: ${target}' }
	e.store.send_mail(target, user.handle, '[TELL] ' + msg) or { return 'Failed: ${err}' }
	return 'Told ${target}.'
}

// profile: view a user's bio, or set your own with SETBIO.
fn (mut e Engine) profile(args string) string {
	target := args.trim_space()
	if target.len == 0 {
		return 'Usage: PROFILE <user>'
	}
	u := e.store.get_user(target) or { return 'No such user: ${target}' }
	bio := if u.bio.len > 0 { u.bio } else { '(no bio set)' }
	return '${u.handle} [${perm_from_int(u.perm).str_name()}]\n${bio}'
}

fn (mut e Engine) set_bio(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN to set a bio.' }
	e.store.set_user_bio(user.handle, args.trim_space()) or { return 'Failed: ${err}' }
	return 'Bio updated.'
}
