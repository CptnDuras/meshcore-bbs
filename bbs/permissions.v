module main

// Permission levels (Spec 10), ordered low->high.
pub enum Perm as u8 {
	unverified = 0
	twit       = 1
	user       = 2
	aide       = 3
	sysop      = 4
}

// perm_from_int clamps an int to a valid Perm.
pub fn perm_from_int(v int) Perm {
	if v <= 0 {
		return .unverified
	}
	if v >= 4 {
		return .sysop
	}
	return unsafe { Perm(u8(v)) }
}

pub fn (p Perm) str_name() string {
	return match p {
		.unverified { 'unverified' }
		.twit { 'twit' }
		.user { 'user' }
		.aide { 'aide' }
		.sysop { 'sysop' }
	}
}

// min_level returns the minimum permission required to perform an action.
pub fn min_level(action string) Perm {
	return match action {
		'read', 'who', 'help', 'list', 'oneliner_read', 'bulletin_read' { Perm.unverified }
		'post', 'mail', 'enter', 'tell', 'oneliner_post', 'reply', 'poll_create', 'vote',
		'channel_add' {
			Perm.user
		}
		'create_room', 'delete_room', 'verify_user', 'set_perm', 'delete_message',
		'move_message', 'ban_user', 'twit_user' {
			Perm.aide
		}
		'sysop_config', 'bulletin_post', 'broadcast' { Perm.sysop }
		else { Perm.sysop } // unknown actions default to most-restrictive
	}
}

// has_permission checks whether a user may perform an action.
// Banned users and TWITs are handled specially by callers where needed; here we
// enforce the numeric level and deny banned users everything but read/who/help.
pub fn has_permission(u User, action string) bool {
	if u.banned {
		return action in ['read', 'who', 'help', 'list']
	}
	return int(perm_from_int(u.perm)) >= int(min_level(action))
}

// can_set_perm: an actor may set a target's permission only if the actor is
// AIDE+ and the new level is strictly below the actor's own level (an AIDE
// cannot create a SYSOP or another AIDE at/above themselves).
pub fn can_set_perm(actor User, new_level Perm) bool {
	actor_level := perm_from_int(actor.perm)
	if int(actor_level) < int(Perm.aide) {
		return false
	}
	return int(new_level) < int(actor_level)
}
