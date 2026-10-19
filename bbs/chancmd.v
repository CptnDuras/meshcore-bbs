module main

// Slash commands on a public channel: someone posts `/weather` and the BBS
// answers on the same channel. Channel text arrives as "SenderName: message".
//
// A public channel is shared airtime, so this is deliberately stingy:
//   - only a short list of known commands answers; anything else is ignored
//   - the same sender can use a command once a minute
//   - the whole channel gets at most 6 replies per 5 minutes
//   - replies are one message (the forecast is trimmed to today + tonight)
// Turn it off with the web UI (Alerts page) setting `chan_commands`.

const chan_cmd_per_sender_secs = i64(60)
const chan_cmd_window_secs = i64(300)
const chan_cmd_window_max = 6

struct ChanCommand {
	sender string
	cmd    string // lower-case, without the slash
	args   string
}

// parse_channel_command splits "Name: /cmd args" into its parts. Returns none
// if the text is not a slash command. A bare "/cmd args" (no sender prefix) is
// accepted too, with an empty sender.
fn parse_channel_command(text string) ?ChanCommand {
	mut sender := ''
	mut body := text.trim_space()
	if !body.starts_with('/') {
		i := body.index(': ') or { return none }
		sender = body[..i].trim_space()
		body = body[i + 2..].trim_space()
	}
	if !body.starts_with('/') || body.len < 2 {
		return none
	}
	parts := body[1..].split(' ')
	cmd := parts[0].to_lower()
	if cmd.len == 0 || cmd.len > 16 {
		return none
	}
	args := if parts.len > 1 { parts[1..].join(' ').trim_space() } else { '' }
	return ChanCommand{
		sender: sender
		cmd:    cmd
		args:   args
	}
}

// chan_command_known maps aliases to the command we answer.
fn chan_command_known(cmd string) string {
	return match cmd {
		'weather', 'wx' { 'weather' }
		'forecast', 'fc' { 'forecast' }
		'alerts', 'alert' { 'alerts' }
		'help', 'commands' { 'help' }
		else { '' }
	}
}

// chan_cmd_allowed applies the per-sender and per-channel limits and, if the
// command may run, records it. Pure apart from the passed-in state.
fn chan_cmd_allowed(mut last map[string]i64, mut recent []i64, key string, now i64) bool {
	if (last[key] or { 0 }) > 0 && now - (last[key] or { 0 }) < chan_cmd_per_sender_secs {
		return false
	}
	mut keep := []i64{}
	for t in recent {
		if now - t < chan_cmd_window_secs {
			keep << t
		}
	}
	recent = keep.clone()
	if recent.len >= chan_cmd_window_max {
		return false
	}
	recent << now
	last[key] = now
	return true
}

// channel_command_reply builds the reply text for a known command ('' if none).
// `fetch` hooks make it testable without network.
fn channel_command_reply(cmd string) string {
	return match cmd {
		'weather' { fetch_weather() }
		'forecast' { fetch_forecast(1) }
		'alerts' { fetch_alerts_report() }
		'help' { 'meshbbs: /weather /forecast /alerts. DM me for the full BBS (send HELP).' }
		else { '' }
	}
}

fn (mut e Engine) chan_commands_enabled() bool {
	return (e.store.alert_get('chan_commands') or { '1' }) != '0'
}

// handle_channel_command is called for every channel message the radio reports.
// If it is an answerable, allowed slash command it queues one reply on the
// channel it came from and returns the command; otherwise returns ''.
fn (mut e Engine) handle_channel_command(chan_idx int, text string, now i64) string {
	c := parse_channel_command(text) or { return '' }
	cmd := chan_command_known(c.cmd)
	if cmd.len == 0 || !e.chan_commands_enabled() {
		return ''
	}
	if c.sender.to_lower() == e.name.to_lower() {
		return '' // never answer ourselves
	}
	key := '${chan_idx}:${c.sender}:${cmd}'
	if !chan_cmd_allowed(mut e.chan_cmd_last, mut e.chan_cmd_recent, key, now) {
		return ''
	}
	reply := channel_command_reply(cmd)
	if reply.len == 0 {
		return ''
	}
	who := if c.sender.len > 0 { '@[${c.sender}] ' } else { '' }
	e.store.enqueue_outbound(target_chan, chan_idx.str(), who + reply) or { return '' }
	return cmd
}
