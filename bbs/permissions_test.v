module main

fn test_perm_from_int_clamps() {
	assert perm_from_int(-5) == Perm.unverified
	assert perm_from_int(0) == Perm.unverified
	assert perm_from_int(2) == Perm.user
	assert perm_from_int(4) == Perm.sysop
	assert perm_from_int(99) == Perm.sysop
}

fn test_perm_str_name() {
	assert Perm.unverified.str_name() == 'unverified'
	assert Perm.twit.str_name() == 'twit'
	assert Perm.user.str_name() == 'user'
	assert Perm.aide.str_name() == 'aide'
	assert Perm.sysop.str_name() == 'sysop'
}

fn test_min_level_map() {
	assert min_level('read') == Perm.unverified
	assert min_level('who') == Perm.unverified
	assert min_level('post') == Perm.user
	assert min_level('mail') == Perm.user
	assert min_level('create_room') == Perm.aide
	assert min_level('verify_user') == Perm.aide
	assert min_level('sysop_config') == Perm.sysop
	// unknown action defaults to most restrictive
	assert min_level('totally_unknown') == Perm.sysop
}

fn test_has_permission_levels() {
	unverified := User{
		perm: int(Perm.unverified)
	}
	usr := User{
		perm: int(Perm.user)
	}
	aide := User{
		perm: int(Perm.aide)
	}
	sysop := User{
		perm: int(Perm.sysop)
	}

	// unverified can read but not post
	assert has_permission(unverified, 'read')
	assert !has_permission(unverified, 'post')
	// user can post/mail but not create rooms
	assert has_permission(usr, 'post')
	assert has_permission(usr, 'mail')
	assert !has_permission(usr, 'create_room')
	// aide can create rooms + verify, not sysop_config
	assert has_permission(aide, 'create_room')
	assert has_permission(aide, 'verify_user')
	assert !has_permission(aide, 'sysop_config')
	// sysop can do everything
	assert has_permission(sysop, 'sysop_config')
}

fn test_banned_user_restricted() {
	banned := User{
		perm:   int(Perm.user)
		banned: true
	}
	assert has_permission(banned, 'read')
	assert has_permission(banned, 'who')
	assert !has_permission(banned, 'post')
	assert !has_permission(banned, 'mail')
}

fn test_can_set_perm_rules() {
	aide := User{
		perm: int(Perm.aide)
	}
	sysop := User{
		perm: int(Perm.sysop)
	}
	usr := User{
		perm: int(Perm.user)
	}
	// aide can set below own level
	assert can_set_perm(aide, Perm.user)
	assert can_set_perm(aide, Perm.twit)
	// aide cannot set at/above own level
	assert !can_set_perm(aide, Perm.aide)
	assert !can_set_perm(aide, Perm.sysop)
	// sysop can set aide
	assert can_set_perm(sysop, Perm.aide)
	// plain user cannot set perms at all
	assert !can_set_perm(usr, Perm.user)
}
