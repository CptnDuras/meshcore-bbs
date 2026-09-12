module main

// Channel directory (TC2-BBS parity): users publish community channels so
// newcomers can find them.
//
// Commands:
//   CHANNELS                                  list directory
//   CHANADD <name>|<description>[|<join info>] add a channel (verified users)

fn (mut e Engine) channels_list() string {
	chans := e.store.list_channels(20)
	if chans.len == 0 {
		return 'Channel directory is empty. CHANADD <name>|<desc>[|<info>] to add one.'
	}
	mut b := '== Channels ==\n'
	for c in chans {
		b += '- ${c.name}: ${c.descr}'
		if c.info.len > 0 {
			b += ' (${c.info})'
		}
		b += '\n'
	}
	return b.trim_right('\n')
}

fn (mut e Engine) channel_add(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN to add a channel.' }
	if !has_permission(user, 'channel_add') {
		return 'You are not verified yet.'
	}
	// format: <name>|<description>[|<join info>]
	parts := args.split('|')
	if parts.len < 2 {
		return 'Usage: CHANADD <name>|<description>[|<join info>]'
	}
	name := parts[0].trim_space()
	descr := parts[1].trim_space()
	info := if parts.len >= 3 { parts[2].trim_space() } else { '' }
	if name.len == 0 || descr.len == 0 {
		return 'Channel name and description are required.'
	}
	e.store.add_channel(name, descr, info, user.handle) or { return 'Failed: ${err}' }
	return 'Added channel "${name}" to the directory.'
}
