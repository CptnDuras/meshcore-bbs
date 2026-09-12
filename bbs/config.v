module main

// /CONFIG — user self-service configuration.
//   CONFIG                      show this menu + your settings
//   CONFIG ADDCMD <name> <text> define a custom text-macro command
//   CONFIG DELCMD <name>        remove one of your custom commands
//   CONFIG CMDS                 list your custom commands
//   CONFIG SET <key> <value>    set a preference (e.g. digest on)
//   CONFIG PREFS                list your preferences
//
// Custom commands are TEXT MACROS only (no scripting): sending the macro name
// replies with its stored text. They can't shadow built-in commands.

fn (mut e Engine) config(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'No account.' }
	a := args.trim_space()
	if a.len == 0 {
		return e.config_overview(user.handle)
	}
	parts := a.split(' ')
	sub := parts[0].to_upper()
	rest := if parts.len > 1 { parts[1..].join(' ') } else { '' }
	match sub {
		'ADDCMD' {
			return e.config_addcmd(user.handle, rest)
		}
		'DELCMD' {
			return e.config_delcmd(user.handle, rest)
		}
		'CMDS' {
			return e.config_cmds(user.handle)
		}
		'SET' {
			return e.config_set(user.handle, rest)
		}
		'PREFS' {
			return e.config_prefs(user.handle)
		}
		else {
			return 'CONFIG options: ADDCMD <name> <text> | DELCMD <name> | CMDS | SET <key> <val> | PREFS'
		}
	}
}

fn (mut e Engine) config_overview(owner string) string {
	macros := e.store.list_macros(owner)
	prefs := e.store.list_prefs(owner)
	mut b := '== /CONFIG ==\n'
	b += 'Custom cmds: ${macros.len} (CONFIG CMDS to list)\n'
	b += 'Preferences: ${prefs.len} (CONFIG PREFS to list)\n'
	b += 'Add a command: CONFIG ADDCMD <name> <text>\n'
	b += 'Set a pref:    CONFIG SET <key> <value>'
	return b
}

fn (mut e Engine) config_addcmd(owner string, rest string) string {
	p := rest.split(' ')
	if p.len < 2 {
		return 'Usage: CONFIG ADDCMD <name> <text>'
	}
	name := p[0].to_upper()
	text := p[1..].join(' ')
	if !valid_macro_name(name) {
		return 'Command name must be 1-16 letters/digits.'
	}
	if name in known_commands {
		return 'Cannot override the built-in command ${name}.'
	}
	e.store.add_macro(owner, name, text) or { return 'Failed: ${err}' }
	return 'Custom command ${name} saved. Send ${name} to use it.'
}

fn (mut e Engine) config_delcmd(owner string, rest string) string {
	name := rest.trim_space().to_upper()
	if name.len == 0 {
		return 'Usage: CONFIG DELCMD <name>'
	}
	e.store.get_macro(owner, name) or { return 'No custom command named ${name}.' }
	e.store.delete_macro(owner, name) or { return 'Failed: ${err}' }
	return 'Removed custom command ${name}.'
}

fn (mut e Engine) config_cmds(owner string) string {
	macros := e.store.list_macros(owner)
	if macros.len == 0 {
		return 'No custom commands. Add one: CONFIG ADDCMD <name> <text>'
	}
	mut b := 'Your custom commands:\n'
	for m in macros {
		b += '- ${m.name}: ${m.text}\n'
	}
	return b.trim_right('\n')
}

fn (mut e Engine) config_set(owner string, rest string) string {
	p := rest.split(' ')
	if p.len < 2 {
		return 'Usage: CONFIG SET <key> <value>'
	}
	key := p[0].to_lower()
	val := p[1..].join(' ')
	e.store.set_pref(owner, key, val) or { return 'Failed: ${err}' }
	return 'Set ${key} = ${val}.'
}

fn (mut e Engine) config_prefs(owner string) string {
	prefs := e.store.list_prefs(owner)
	if prefs.len == 0 {
		return 'No preferences set. Try: CONFIG SET digest on'
	}
	mut b := 'Your preferences:\n'
	for p in prefs {
		b += '- ${p.key} = ${p.val}\n'
	}
	return b.trim_right('\n')
}

// lookup_macro returns the reply text for a user's custom command, or none.
// Called from the unknown-command fallback so macros never shadow built-ins.
fn (mut e Engine) lookup_macro(sess Session, cmd string) ?string {
	if sess.handle.len == 0 {
		return none
	}
	m := e.store.get_macro(sess.handle, cmd.to_upper()) or { return none }
	return m.text
}

// valid_macro_name allows 1-16 alphanumeric chars.
fn valid_macro_name(name string) bool {
	if name.len < 1 || name.len > 16 {
		return false
	}
	for c in name {
		if !((c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`)) {
			return false
		}
	}
	return true
}
