module main

import os
import time

// Emergency weather alerts from the US National Weather Service (no key needed).
//
// Every few minutes the daemon asks api.weather.gov for the active alerts in
// Wyoming and keeps the ones that cover Sheridan or Johnson county (matched on
// the county SAME/FIPS codes in each alert's geocode, so a zone alert such as
// "Johnson County" or "Sheridan County Plains" counts too). Each new alert is
//   - published to the public channel (0), and
//   - for Warning-level and above (Warning, Emergency, or severity Extreme),
//     sent as a DM to every node that has ever talked to the BBS, unless the
//     user opted out with `CONFIG SET alerts off`.
// Alerts are remembered by event + counties, so an NWS update to an alert that
// is still active is not announced twice; the key is dropped a few hours after
// the alert leaves the feed so a later, separate event of the same kind is.

const alerts_area = 'WY'
const alerts_poll_secs = i64(2 * 60)
const alerts_forget_secs = i64(6 * 60 * 60) // keep a sent key this long after the alert leaves the feed
const alerts_channel = '0'

// Counties we call out. `same` is the FIPS code as it appears in NWS geocode.SAME.
struct AlertCounty {
	same string
	name string
}

const alert_counties = [
	AlertCounty{
		same: '056033'
		name: 'Sheridan'
	},
	AlertCounty{
		same: '056019'
		name: 'Johnson'
	},
]

// LocalAlert is an NWS alert that touches one of our counties.
struct LocalAlert {
	key      string // dedupe key: event + counties
	event    string
	counties []string // names, in alert_counties order
	until    i64      // epoch secs, 0 if unknown
	until_s  string   // wall-clock text from the NWS timestamp, e.g. "Sun 6AM"
	sent_ts  i64      // when NWS issued it (epoch secs), 0 if unknown
	sent_s   string   // wall-clock text of that, e.g. "Thu 12:23PM"
	urgent   bool
}

// alert_is_urgent: Warning-level and above. Warnings and Emergencies (Tornado
// Emergency, Flash Flood Emergency, ...) always count; so does anything NWS
// itself rates Extreme.
fn alert_is_urgent(event string, severity string) bool {
	ev := event.to_lower()
	return ev.ends_with('warning') || ev.ends_with('emergency') || severity == 'Extreme'
}

// local_alert_from turns one NWS feature's properties into a LocalAlert, or
// none if it is not an actual, uncancelled alert for our counties that is
// still active at `now`.
fn local_alert_from(p JVal, now i64) ?LocalAlert {
	event := p.str_of('event')
	if event.len == 0 || p.str_of('status') != 'Actual' || p.str_of('messageType') == 'Cancel' {
		return none
	}
	mut same := []string{}
	for z in p.get('geocode').get('SAME').arr {
		same << z.s
	}
	mut names := []string{}
	for c in alert_counties {
		if c.same in same {
			names << c.name
		}
	}
	if names.len == 0 {
		return none
	}
	ends := p.str_of('ends')
	end := if ends.len > 0 { ends } else { p.str_of('expires') }
	until, until_s := parse_nws_time(end)
	if until > 0 && until < now {
		return none
	}
	sent_ts, sent_s := parse_nws_time(p.str_of('sent'))
	return LocalAlert{
		key:      '${event}|${names.join('+')}'
		event:    event
		counties: names
		until:    until
		until_s:  until_s
		sent_ts:  sent_ts
		sent_s:   sent_s
		urgent:   alert_is_urgent(event, p.str_of('severity'))
	}
}

// parse_local_alerts keeps the actual, still-active alerts for our counties.
// `now` is epoch secs; alerts already expired are dropped. Pure (no I/O).
fn parse_local_alerts(body string, now i64) []LocalAlert {
	root := parse_json(body) or { return []LocalAlert{} }
	mut out := []LocalAlert{}
	for f in root.get('features').arr {
		if a := local_alert_from(f.get('properties'), now) {
			out << a
		}
	}
	return out
}

// pick_example_alert chooses a real PAST alert from an NWS history response
// (alerts?area=..&start=..&end=..) to replay in a test: the most recently sent
// Warning-level alert for our counties, else the most recent of any kind. Each
// alert is judged as of the moment it was sent, so expired ones still qualify.
fn pick_example_alert(body string) ?LocalAlert {
	root := parse_json(body) or { return none }
	mut best := LocalAlert{}
	mut best_urgent := LocalAlert{}
	for f in root.get('features').arr {
		p := f.get('properties')
		sent_ts, _ := parse_nws_time(p.str_of('sent'))
		a := local_alert_from(p, sent_ts) or { continue }
		if a.sent_ts > best.sent_ts {
			best = a
		}
		if a.urgent && a.sent_ts > best_urgent.sent_ts {
			best_urgent = a
		}
	}
	if best_urgent.sent_ts > 0 {
		return best_urgent
	}
	if best.sent_ts > 0 {
		return best
	}
	return none
}

// parse_nws_time reads an NWS timestamp such as 2026-10-19T06:00:00-06:00 and
// returns the epoch secs plus the wall-clock text in the office's own zone
// ("Mon 6AM", "Mon 6:30PM"). Returns (0, '') if it cannot be parsed.
fn parse_nws_time(s string) (i64, string) {
	t := time.parse_rfc3339(s) or { return 0, '' }
	// the offset is the last 6 chars (+hh:mm / -hh:mm), or a trailing Z
	mut off := 0
	if s.len >= 6 && (s[s.len - 6] == `+` || s[s.len - 6] == `-`) && s[s.len - 3] == `:` {
		sign := if s[s.len - 6] == `-` { -1 } else { 1 }
		off = sign * (s[s.len - 5..s.len - 3].int() * 3600 + s[s.len - 2..].int() * 60)
	}
	local := time.unix(t.unix() + off)
	days := ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
	h := local.hour % 12
	hh := if h == 0 { 12 } else { h }
	ap := if local.hour < 12 { 'AM' } else { 'PM' }
	mm := if local.minute == 0 { '' } else { ':${local.minute:02d}' }
	return t.unix(), '${days[local.day_of_week() % 7]} ${hh}${mm}${ap}'
}

// county_label: "Sheridan Co", "Johnson Co" or "Sheridan+Johnson Co".
fn county_label(names []string) string {
	return names.join('+') + ' Co'
}

// format_alert builds the broadcast text: one short line that fits a single
// mesh message. Warning-level alerts are upper-cased and tell people to act.
fn format_alert(a LocalAlert) string {
	head := if a.urgent { 'NWS ALERT ${a.event.to_upper()}' } else { 'NWS ${a.event}' }
	mut s := '${head} - ${county_label(a.counties)} WY'
	if a.until_s.len > 0 {
		s += ' until ${a.until_s}'
	}
	s += '.'
	if a.urgent {
		s += ' Take action now.'
	}
	return s
}

// fetch_alerts_body is the one I/O call (curl, like the other NWS fetchers).
fn fetch_alerts_body() ?string {
	url := 'https://api.weather.gov/alerts/active?area=${alerts_area}'
	res := os.execute("curl -sf -m 15 -H 'User-Agent: ${wx_ua}' -H 'Accept: application/geo+json' '${url}'")
	if res.exit_code != 0 || res.output.len == 0 {
		return none
	}
	return res.output
}

// alerts_report is the text for the ALERTS command: what is active right now.
fn alerts_report(body string, now i64) string {
	alerts := parse_local_alerts(body, now)
	if alerts.len == 0 {
		return 'No active NWS alerts for Sheridan or Johnson Co WY.'
	}
	mut lines := []string{}
	for a in alerts {
		lines << format_alert(a)
	}
	return lines.join('\n')
}

fn fetch_alerts_report() string {
	body := fetch_alerts_body() or { return 'ALERTS: could not reach weather service' }
	return alerts_report(body, time.now().unix())
}

// --- who gets alerts: restricted (test) vs public ---------------------------
//
// Setting `alert_scope` (stored in the DB, flipped from the web UI):
//   restricted (default) every alert, real or test, goes ONLY as a DM to the
//                        test node (`alert_test_node`); nothing reaches the
//                        public channel or any other node.
//   public               real behaviour: channel post, plus DMs to everyone
//                        for Warning-level alerts.
const alert_scope_restricted = 'restricted'
const alert_scope_public = 'public'

fn (mut e Engine) alerts_public() bool {
	return (e.store.alert_get('alert_scope') or { alert_scope_restricted }) == alert_scope_public
}

// alert_test_node is the node restricted scope sends to; set from the web UI.
// Empty means nobody: restricted scope then sends nothing at all.
fn (mut e Engine) alert_test_node() string {
	return valid_node_prefix(e.store.alert_get('alert_test_node') or { '' })
}

// valid_node_prefix returns `s` if it is a plausible hex pubkey prefix, else ''.
fn valid_node_prefix(s string) string {
	p := s.trim_space().to_lower()
	if p.len < 4 || p.len > 64 {
		return ''
	}
	for c in p {
		if !((c >= `0` && c <= `9`) || (c >= `a` && c <= `f`)) {
			return ''
		}
	}
	return p
}

// wants_alert_dm: every node that has a session gets DMs unless it opted out.
fn (mut e Engine) wants_alert_dm(sess Session) bool {
	handle := if sess.handle.len > 0 { sess.handle } else { node_handle(sess.pubkey_prefix) }
	v := e.store.get_pref(handle, 'alerts') or { return true }
	return v.to_lower() !in ['off', '0', 'no', 'false']
}

// alert_dm_targets lists the nodes to DM. Restricted: just the test node.
// Public: every opted-in node with a session.
fn (mut e Engine) alert_dm_targets() []string {
	if !e.alerts_public() {
		node := e.alert_test_node()
		return if node.len > 0 { [node] } else { []string{} }
	}
	mut out := []string{}
	for sess in e.store.list_sessions() {
		if sess.pubkey_prefix.len > 0 && e.wants_alert_dm(sess) {
			out << sess.pubkey_prefix
		}
	}
	return out
}

// send_alert_messages queues `msgs` (in order) for the right audience.
//   everyone=false -> one DM target only (`only`)
//   everyone=true  -> channel (public scope only) + all DM targets
// In restricted scope everything collapses to the test node. Returns a short
// description of where it went.
fn (mut e Engine) send_alert_messages(msgs []string, to_channel bool, to_dms bool) string {
	mut dest := []string{}
	if to_channel && e.alerts_public() {
		for m in msgs {
			e.store.enqueue_outbound(target_chan, alerts_channel, m) or {}
		}
		dest << 'channel'
	}
	if to_dms {
		targets := e.alert_dm_targets()
		for t in targets {
			for m in msgs {
				e.store.enqueue_outbound(target_dm, t, m) or {}
			}
		}
		if targets.len > 0 {
			dest << '${targets.len} DM(s)'
		}
	}
	return dest.join(' + ')
}

// process_alerts handles one NWS response: announces new alerts and returns how
// many were announced. Pure apart from the store, so it is testable with
// fixture bodies.
fn (mut e Engine) process_alerts(body string, now i64) int {
	alerts := parse_local_alerts(body, now)
	mut announced := 0
	for a in alerts {
		if e.store.alert_key_touch(a.key, now) {
			continue // already announced and still active
		}
		where := e.send_alert_messages([format_alert(a)], true, a.urgent || !e.alerts_public())
		println('[alerts] ${a.key}: ${where}')
		announced++
	}
	e.store.alert_keys_prune(now - alerts_forget_secs) or {}
	e.store.alert_set('last_active', alerts.len.str()) or {}
	return announced
}

// poll_alerts fetches and processes; failures are logged and retried next poll.
// Status goes to the DB so the web UI can show that we are really subscribed.
fn (mut e Engine) poll_alerts(now i64) {
	e.store.alert_set('last_poll', now.str()) or {}
	body := fetch_alerts_body() or {
		eprintln('[alerts] NWS fetch failed')
		e.store.alert_set('last_poll_ok', '0') or {}
		return
	}
	e.store.alert_set('last_poll_ok', '1') or {}
	e.process_alerts(body, now)
}

// --- test mode ---------------------------------------------------------------
//
// A test sends a REAL past alert (the most recent Warning-level one NWS issued
// for our counties) wrapped in a pre-message and a post-message that say it is
// a test, so nobody mistakes it for the real thing. If NWS history cannot be
// fetched, a built-in sample is used instead.
const alert_test_pre = '*** TEST *** This is a TEST of the meshbbs emergency weather alert system. No action needed.'
const alert_test_post = '*** END OF TEST *** That was only a TEST of the meshbbs emergency weather alert system.'

fn fetch_alert_history_body() ?string {
	now := time.now().unix()
	fmt := fn (t i64) string {
		return time.unix(t).format_rfc3339()
	}
	url := 'https://api.weather.gov/alerts?area=${alerts_area}&start=${fmt(now - 60 * 86400)}&end=${fmt(now)}&limit=500'
	res := os.execute("curl -sf -m 25 -H 'User-Agent: ${wx_ua}' -H 'Accept: application/geo+json' '${url}'")
	if res.exit_code != 0 || res.output.len == 0 {
		return none
	}
	return res.output
}

// alert_test_messages builds [pre, alert, post]. `history_body` is an NWS
// history response ('' -> fall back to the built-in sample).
fn alert_test_messages(history_body string) []string {
	mut line := ''
	if a := pick_example_alert(history_body) {
		line = 'TEST (replay of the real alert NWS sent ${a.sent_s}): ' + format_alert(a)
	} else {
		sample := LocalAlert{
			event:    'Tornado Warning'
			counties: ['Sheridan', 'Johnson']
			until_s:  'now+1h'
			urgent:   true
		}
		line = 'TEST (made-up sample): ' + format_alert(sample)
	}
	return [alert_test_pre, line, alert_test_post]
}

// Test targets (a request's / ALERTTEST's destination):
//   scope        whatever real alerts would reach right now (restricted -> the
//                restricted node, public -> channel + opted-in nodes)
//   chan         the public channel only
//   node:<hex>   a DM to one node
const alert_target_scope = 'scope'
const alert_target_chan = 'chan'

// queue_alert_test queues [pre, alert, post] for `target`. Returns where it
// went, or an error text starting with "ERR:".
fn (mut e Engine) queue_alert_test(history_body string, target string) string {
	msgs := alert_test_messages(history_body)
	t := target.trim_space().to_lower()
	if t == alert_target_chan {
		for m in msgs {
			e.store.enqueue_outbound(target_chan, alerts_channel, m) or {}
		}
		return 'public channel'
	}
	if t.starts_with('node:') {
		node := valid_node_prefix(t['node:'.len..])
		if node.len == 0 {
			return 'ERR: bad node id'
		}
		for m in msgs {
			e.store.enqueue_outbound(target_dm, node, m) or {}
		}
		return 'DM to ${node}'
	}
	where := e.send_alert_messages(msgs, true, true)
	return if where.len > 0 { where } else { 'nobody (no restricted node is set)' }
}

// ALERTTEST (sysop only):
//   ALERTTEST          DM to you
//   ALERTTEST CHAN     the public channel
//   ALERTTEST ALL      the current scope's audience (like a real alert)
//   ALERTTEST <nodeid> DM to that node (hex pubkey prefix)
fn (mut e Engine) alert_test(sess Session, args string) string {
	user := e.current_user(sess) or { return 'No account.' }
	if !has_permission(user, 'broadcast') {
		return 'ALERTTEST is for sysops only.'
	}
	a := args.trim_space().to_lower()
	target := match true {
		a == '' { 'node:${sess.pubkey_prefix}' }
		a == 'chan' { alert_target_chan }
		a == 'all' { alert_target_scope }
		valid_node_prefix(a).len > 0 { 'node:${a}' }
		else { '' }
	}
	if target.len == 0 {
		return 'Usage: ALERTTEST (DM to you) | ALERTTEST CHAN | ALERTTEST ALL | ALERTTEST <nodeid>'
	}
	history := fetch_alert_history_body() or { '' }
	return 'Test alert queued (pre, alert, post) -> ${e.queue_alert_test(history, target)}.'
}

// handle_alert_requests runs test requests queued by the web UI.
fn (mut e Engine) handle_alert_requests() {
	pending := e.store.alert_requests_pending()
	if pending.len == 0 {
		return
	}
	history := fetch_alert_history_body() or { '' }
	e.handle_alert_requests_with(pending, history)
}

fn (mut e Engine) handle_alert_requests_with(pending []AlertRequest, history string) {
	for r in pending {
		note := e.queue_alert_test(history, r.target)
		e.store.alert_request_done(r.id, note) or {}
		println('[alerts] web test #${r.id} -> ${note}')
	}
}
