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
	assert 'ALERTS' in known_commands
}
