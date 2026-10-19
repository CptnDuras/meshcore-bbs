module main

// Offline tests for the NWS emergency-alert feature. The fixture mirrors the
// api.weather.gov /alerts/active geo+json shape.

fn alert_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	return Engine{
		store: store
		name:  'alertbbs'
	}
}

fn alert_feature(id string, event string, severity string, same string, status string, ends string) string {
	return '{"id":"${id}","type":"Feature","properties":{"id":"${id}","areaDesc":"x","event":"${event}",' +
		'"severity":"${severity}","status":"${status}","messageType":"Alert","headline":"${event} issued",' +
		'"expires":"${ends}","ends":"${ends}","geocode":{"SAME":[${same}],"UGC":["WYZ001"]}}}'
}

fn alerts_body(features []string) string {
	return '{"type":"FeatureCollection","features":[' + features.join(',') + ']}'
}

const now_ts = i64(1792368000) // 2026-10-19T00:00:00Z

fn test_urgent_levels() {
	assert alert_is_urgent('Winter Storm Warning', 'Severe')
	assert alert_is_urgent('Tornado Emergency', 'Extreme')
	assert alert_is_urgent('Blizzard Warning', 'Severe')
	assert alert_is_urgent('Something Odd', 'Extreme')
	assert !alert_is_urgent('Winter Storm Watch', 'Severe')
	assert !alert_is_urgent('Wind Advisory', 'Moderate')
	assert !alert_is_urgent('Special Weather Statement', 'Moderate')
}

fn test_only_our_counties_kept() {
	body := alerts_body([
		alert_feature('a', 'Winter Storm Warning', 'Severe', '"056033","056005"', 'Actual', '2026-10-19T23:00:00-06:00'),
		alert_feature('b', 'Wind Advisory', 'Moderate', '"056019"', 'Actual', '2026-10-19T23:00:00-06:00'),
		alert_feature('c', 'Flood Warning', 'Severe', '"056005"', 'Actual', '2026-10-19T23:00:00-06:00'),
	])
	got := parse_local_alerts(body, now_ts)
	assert got.len == 2
	assert got[0].event == 'Winter Storm Warning'
	assert got[0].counties == ['Sheridan']
	assert got[0].urgent
	assert got[1].counties == ['Johnson']
	assert !got[1].urgent
}

fn test_both_counties_label() {
	body := alerts_body([
		alert_feature('a', 'High Wind Warning', 'Severe', '"056019","056033"', 'Actual', '2026-10-19T23:00:00-06:00'),
	])
	got := parse_local_alerts(body, now_ts)
	assert got.len == 1
	assert county_label(got[0].counties) == 'Sheridan+Johnson Co'
}

fn test_tests_and_expired_skipped() {
	body := alerts_body([
		alert_feature('a', 'Tornado Warning', 'Extreme', '"056033"', 'Test', '2026-10-19T23:00:00-06:00'),
		alert_feature('b', 'Flood Warning', 'Severe', '"056033"', 'Actual', '2026-10-18T10:00:00-06:00'),
	])
	assert parse_local_alerts(body, now_ts).len == 0
}

fn test_parse_nws_time_wall_clock() {
	// 2026-10-19 is a Monday
	ts, s := parse_nws_time('2026-10-19T06:00:00-06:00')
	assert ts == 1792411200
	assert s == 'Mon 6AM'
	_, s2 := parse_nws_time('2026-10-19T18:30:00-06:00')
	assert s2 == 'Mon 6:30PM'
	_, s3 := parse_nws_time('2026-10-19T00:00:00-06:00')
	assert s3 == 'Mon 12AM'
	ts4, s4 := parse_nws_time('garbage')
	assert ts4 == 0 && s4 == ''
}

fn test_format_alert() {
	body := alerts_body([
		alert_feature('a', 'Winter Storm Warning', 'Severe', '"056033"', 'Actual', '2026-10-19T06:00:00-06:00'),
		alert_feature('b', 'Wind Advisory', 'Moderate', '"056019"', 'Actual', '2026-10-19T06:00:00-06:00'),
	])
	got := parse_local_alerts(body, now_ts)
	w := format_alert(got[0])
	assert w == 'NWS ALERT WINTER STORM WARNING - Sheridan Co WY until Mon 6AM. Take action now.'
	assert w.len <= 160
	adv := format_alert(got[1])
	assert adv == 'NWS Wind Advisory - Johnson Co WY until Mon 6AM.'
}

fn test_bad_json_is_empty() {
	assert parse_local_alerts('not json', now_ts).len == 0
	assert parse_local_alerts('', now_ts).len == 0
}

fn test_alerts_report_text() {
	assert alerts_report(alerts_body([]), now_ts).contains('No active NWS alerts')
	body := alerts_body([
		alert_feature('a', 'Flood Warning', 'Severe', '"056033"', 'Actual', '2026-10-19T06:00:00-06:00'),
	])
	assert alerts_report(body, now_ts).contains('FLOOD WARNING')
}

fn test_process_publishes_once_and_dms_only_warnings() {
	mut e := alert_engine()
	e.store.alert_set('alert_scope', 'public') or { panic(err) }
	e.handle('aa', 'HELP') // creates sessions for two nodes
	e.handle('bb', 'HELP')
	body := alerts_body([
		alert_feature('a', 'Winter Storm Warning', 'Severe', '"056033"', 'Actual', '2026-10-19T06:00:00-06:00'),
		alert_feature('b', 'Wind Advisory', 'Moderate', '"056019"', 'Actual', '2026-10-19T06:00:00-06:00'),
	])
	base := e.store.count_outbound_pending()
	assert e.process_alerts(body, now_ts) == 2
	out := e.store.pending_outbound(100)
	assert out.len - base == 2 + 2 // 2 channel posts + 2 DMs for the warning only
	mut chan := 0
	mut dms := 0
	for m in out {
		if m.target_kind == target_chan {
			chan++
		} else {
			dms++
			assert m.text.contains('WINTER STORM WARNING')
		}
	}
	assert chan == 2
	assert dms == 2
	// same feed again -> nothing new
	assert e.process_alerts(body, now_ts + 300) == 0
	assert e.store.count_outbound_pending() == out.len
}

fn test_opt_out_skips_dm() {
	mut e := alert_engine()
	e.store.alert_set('alert_scope', 'public') or { panic(err) }
	e.handle('aa', 'HELP')
	e.handle('bb', 'HELP')
	e.store.set_pref(node_handle('aa'), 'alerts', 'off') or { panic(err) }
	body := alerts_body([
		alert_feature('a', 'Tornado Warning', 'Extreme', '"056019"', 'Actual', '2026-10-19T06:00:00-06:00'),
	])
	assert e.process_alerts(body, now_ts) == 1
	mut targets := []string{}
	for m in e.store.pending_outbound(100) {
		if m.target_kind == target_dm {
			targets << m.target
		}
	}
	assert targets == ['bb']
}

fn test_reannounced_after_alert_leaves_feed() {
	mut e := alert_engine()
	e.store.alert_set('alert_scope', 'public') or { panic(err) }
	body := alerts_body([
		alert_feature('a', 'Flood Warning', 'Severe', '"056033"', 'Actual', '2026-10-19T23:00:00-06:00'),
	])
	assert e.process_alerts(body, now_ts) == 1
	// gone from the feed for more than the forget window, then back
	assert e.process_alerts(alerts_body([]), now_ts + 3600) == 0
	assert e.process_alerts(alerts_body([]), now_ts + alerts_forget_secs + 7200) == 0
	assert e.process_alerts(body, now_ts + alerts_forget_secs + 7300) == 1
}

fn test_alerts_command() {
	assert standard_commands().find('ALERTS') != none
}

fn history_feature(id string, event string, severity string, same string, status string, mtype string, sent string, ends string) string {
	return '{"id":"${id}","properties":{"id":"${id}","event":"${event}","severity":"${severity}","status":"${status}",' +
		'"messageType":"${mtype}","sent":"${sent}","expires":"${ends}","ends":"${ends}","geocode":{"SAME":[${same}]}}}'
}

fn test_pick_example_prefers_latest_warning_even_if_expired() {
	body := alerts_body([
		history_feature('a', 'Freeze Watch', 'Severe', '"056033"', 'Actual', 'Alert', '2026-10-16T08:00:00-06:00', '2026-10-16T09:00:00-06:00'),
		history_feature('b', 'Freeze Warning', 'Severe', '"056033","056019"', 'Actual', 'Alert', '2026-10-15T12:23:00-06:00', '2026-10-16T09:00:00-06:00'),
		history_feature('c', 'Flood Warning', 'Severe', '"056005"', 'Actual', 'Alert', '2026-10-17T12:00:00-06:00', '2026-10-17T20:00:00-06:00'),
		history_feature('d', 'Winter Storm Warning', 'Severe', '"056019"', 'Actual', 'Alert', '2026-09-01T12:00:00-06:00', '2026-09-02T09:00:00-06:00'),
	])
	a := pick_example_alert(body) or {
		assert false, 'no example'
		return
	}
	assert a.event == 'Freeze Warning'
	assert a.sent_s == 'Thu 12:23PM'
	assert county_label(a.counties) == 'Sheridan+Johnson Co'
	if _ := pick_example_alert(alerts_body([])) {
		assert false, 'should be none'
	}
}

fn test_test_messages_wrap_real_alert_or_sample() {
	body := alerts_body([
		history_feature('b', 'Freeze Warning', 'Severe', '"056033"', 'Actual', 'Alert', '2026-10-15T12:23:00-06:00', '2026-10-16T09:00:00-06:00'),
	])
	m := alert_test_messages(body)
	assert m.len == 3
	assert m[0].starts_with('*** TEST ***')
	assert m[1].contains('replay of the real alert NWS sent Thu 12:23PM')
	assert m[1].contains('NWS ALERT FREEZE WARNING - Sheridan Co WY until Fri 9AM')
	assert m[2].starts_with('*** END OF TEST ***')
	f := alert_test_messages('')
	assert f[1].contains('made-up sample')
}

fn test_restricted_scope_sends_only_to_configured_node() {
	mut e := alert_engine()
	e.handle('aa', 'HELP')
	e.handle('bb', 'HELP')
	body := alerts_body([
		alert_feature('a', 'Tornado Warning', 'Extreme', '"056033"', 'Actual', '2026-10-19T06:00:00-06:00'),
	])
	// nothing configured: restricted scope sends nothing at all
	assert e.process_alerts(body, now_ts) == 1
	assert e.store.count_outbound_pending() == 0
	e.store.alert_set('alert_test_node', 'ABCD1234') or { panic(err) }
	e.process_alerts(alerts_body([
		alert_feature('b', 'Flood Warning', 'Severe', '"056019"', 'Actual', '2026-10-19T06:00:00-06:00'),
	]), now_ts)
	out := e.store.pending_outbound(100)
	assert out.len == 1
	assert out[0].target_kind == target_dm
	assert out[0].target == 'abcd1234'
}

fn test_test_targets() {
	mut e := alert_engine()
	e.handle('aa', 'HELP')
	e.handle('bb', 'HELP')
	assert e.queue_alert_test('', 'chan') == 'public channel'
	assert e.queue_alert_test('', 'node:DEADBEEF01') == 'DM to deadbeef01'
	assert e.queue_alert_test('', 'node:zz').starts_with('ERR')
	assert e.queue_alert_test('', 'scope').contains('nobody')
	out := e.store.pending_outbound(100)
	assert out.len == 6
	assert out[0].target_kind == target_chan && out[0].target == '0'
	assert out[3].target_kind == target_dm && out[3].target == 'deadbeef01'
	for m in out {
		assert m.text.len > 0
	}
	assert out[0].text.starts_with('*** TEST ***')
	assert out[2].text.starts_with('*** END OF TEST ***')
}

// The public-channel test must never look like a real alert: the first message
// announces a test, the alert line itself says TEST, and the last message ends
// the test. All go to channel 0, in that order, and to nobody by DM.
fn test_public_channel_test_is_clearly_marked_and_ordered() {
	mut e := alert_engine()
	e.handle('aa', 'HELP')
	e.handle('bb', 'HELP')
	body := alerts_body([
		history_feature('b', 'Freeze Warning', 'Severe', '"056033"', 'Actual', 'Alert', '2026-10-15T12:23:00-06:00', '2026-10-16T09:00:00-06:00'),
	])
	assert e.queue_alert_test(body, 'chan') == 'public channel'
	out := e.store.pending_outbound(100)
	assert out.len == 3
	for m in out {
		assert m.target_kind == target_chan
		assert m.target == '0'
	}
	assert out[0].id < out[1].id && out[1].id < out[2].id
	assert out[0].text.starts_with('*** TEST ***')
	assert out[1].text.starts_with('TEST (replay of the real alert')
	assert out[1].text.contains('FREEZE WARNING')
	assert out[2].text.starts_with('*** END OF TEST ***')
	for m in out {
		assert m.text.to_upper().contains('TEST')
	}
}

fn test_scope_target_public_reaches_channel_and_everyone() {
	mut e := alert_engine()
	e.handle('aa', 'HELP')
	e.handle('bb', 'HELP')
	e.store.alert_set('alert_scope', 'public') or { panic(err) }
	e.handle_alert_requests_with([AlertRequest{
		id:     1
		target: 'scope'
	}], '')
	assert e.store.pending_outbound(100).len == 3 + 6
}

fn test_web_request_uses_its_target() {
	mut e := alert_engine()
	e.handle_alert_requests_with([AlertRequest{
		id:     1
		target: 'chan'
	}], '')
	out := e.store.pending_outbound(100)
	assert out.len == 3
	assert out[1].target_kind == target_chan
}

fn test_alert_settings_roundtrip() {
	mut e := alert_engine()
	e.store.alert_set('x', '1') or { panic(err) }
	assert (e.store.alert_get('x') or { '' }) == '1'
	e.store.alert_set('x', '2') or { panic(err) }
	assert (e.store.alert_get('x') or { '' }) == '2'
	if _ := e.store.alert_get('nope') {
		assert false, 'should be none'
	}
}

fn test_alerttest_command_targets() {
	mut e := alert_engine()
	e.handle('aa', 'HELP') // first account = sysop
	e.handle('bb', 'HELP') // ordinary user
	assert e.handle('bb', 'ALERTTEST').contains('sysops only')
	assert e.store.count_outbound_pending() == 0
	assert e.handle('aa', 'ALERTTEST bogus!').contains('Usage')
	assert e.handle('aa', 'ALERTTEST CHAN').contains('public channel')
	assert e.handle('aa', 'ALERTTEST abcdef').contains('DM to abcdef')
	assert standard_commands().find('ALERTTEST') != none
}

fn test_valid_node_prefix() {
	assert valid_node_prefix(' D2267935C4D5 ') == 'd2267935c4d5'
	assert valid_node_prefix('xyz1234') == ''
	assert valid_node_prefix('ab') == ''
	assert valid_node_prefix('') == ''
}
