module main

fn chan_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	return Engine{
		store: store
		name:  'MESHBBS'
	}
}

fn test_parse_channel_command() {
	c := parse_channel_command('Alice: /weather') or {
		assert false
		return
	}
	assert c.sender == 'Alice' && c.cmd == 'weather' && c.args == ''
	d := parse_channel_command('Bob Jones: /Forecast 2 days') or {
		assert false
		return
	}
	assert d.sender == 'Bob Jones' && d.cmd == 'forecast' && d.args == '2 days'
	e := parse_channel_command('/wx') or {
		assert false
		return
	}
	assert e.sender == '' && e.cmd == 'wx'
	if _ := parse_channel_command('Alice: hello there') {
		assert false, 'not a command'
	}
	if _ := parse_channel_command('Alice: / ') {
		assert false, 'bare slash'
	}
	if _ := parse_channel_command('no colon here') {
		assert false
	}
}

fn test_known_commands_and_aliases() {
	assert chan_command_known('wx') == 'weather'
	assert chan_command_known('weather') == 'weather'
	assert chan_command_known('fc') == 'forecast'
	assert chan_command_known('alerts') == 'alerts'
	assert chan_command_known('reboot') == ''
}

fn test_limits() {
	mut last := map[string]i64{}
	mut recent := []i64{}
	assert chan_cmd_allowed(mut last, mut recent, 'a', 1000)
	assert !chan_cmd_allowed(mut last, mut recent, 'a', 1030) // same sender+cmd within a minute
	assert chan_cmd_allowed(mut last, mut recent, 'a', 1061)
	// fill the window with different keys
	mut now := i64(2000)
	mut ok := 0
	for i in 0 .. 10 {
		if chan_cmd_allowed(mut last, mut recent, 'k${i}', now) {
			ok++
		}
	}
	assert ok == chan_cmd_window_max
	// after the window passes, allowed again
	assert chan_cmd_allowed(mut last, mut recent, 'z', now + chan_cmd_window_secs + 1)
}

fn test_help_reply_queued_on_same_channel() {
	mut e := chan_engine()
	assert e.handle_channel_command(0, 'Alice: /help', 5000) == 'help'
	out := e.store.pending_outbound(10)
	assert out.len == 1
	assert out[0].target_kind == target_chan && out[0].target == '0'
	assert out[0].text.starts_with('@[Alice] meshbbs:')
	// another channel index replies there
	assert e.handle_channel_command(2, 'Bob: /help', 5000) == 'help'
	assert e.store.pending_outbound(10)[1].target == '2'
}

fn test_ignores_unknown_self_and_disabled() {
	mut e := chan_engine()
	assert e.handle_channel_command(0, 'Alice: /reboot', 100) == ''
	assert e.handle_channel_command(0, 'Alice: good morning', 100) == ''
	assert e.handle_channel_command(0, 'MESHBBS: /help', 100) == ''
	e.store.alert_set('chan_commands', '0') or { panic(err) }
	assert e.handle_channel_command(0, 'Alice: /help', 100) == ''
	assert e.store.count_outbound_pending() == 0
}

fn test_repeat_from_same_sender_is_throttled() {
	mut e := chan_engine()
	assert e.handle_channel_command(0, 'Alice: /help', 100) == 'help'
	assert e.handle_channel_command(0, 'Alice: /help', 130) == ''
	assert e.store.count_outbound_pending() == 1
}
