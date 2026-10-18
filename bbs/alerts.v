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
const alerts_poll_secs = i64(5 * 60)
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
	urgent   bool
}

// alert_is_urgent: Warning-level and above. Warnings and Emergencies (Tornado
// Emergency, Flash Flood Emergency, ...) always count; so does anything NWS
// itself rates Extreme.
fn alert_is_urgent(event string, severity string) bool {
	ev := event.to_lower()
	return ev.ends_with('warning') || ev.ends_with('emergency') || severity == 'Extreme'
}

// parse_local_alerts keeps the actual, still-active alerts for our counties.
// `now` is epoch secs; alerts already expired are dropped. Pure (no I/O).
fn parse_local_alerts(body string, now i64) []LocalAlert {
	root := parse_json(body) or { return []LocalAlert{} }
	mut out := []LocalAlert{}
	for f in root.get('features').arr {
		p := f.get('properties')
		event := p.str_of('event')
		if event.len == 0 || p.str_of('status') != 'Actual' || p.str_of('messageType') == 'Cancel' {
			continue
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
			continue
		}
		ends := p.str_of('ends')
		end := if ends.len > 0 { ends } else { p.str_of('expires') }
		until, until_s := parse_nws_time(end)
		if until > 0 && until < now {
			continue
		}
		out << LocalAlert{
			key:      '${event}|${names.join('+')}'
			event:    event
			counties: names
			until:    until
			until_s:  until_s
			urgent:   alert_is_urgent(event, p.str_of('severity'))
		}
	}
	return out
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

// wants_alert_dm: every node that has a session gets DMs unless it opted out.
fn (mut e Engine) wants_alert_dm(sess Session) bool {
	handle := if sess.handle.len > 0 { sess.handle } else { node_handle(sess.pubkey_prefix) }
	v := e.store.get_pref(handle, 'alerts') or { return true }
	return v.to_lower() !in ['off', '0', 'no', 'false']
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
		text := format_alert(a)
		e.store.enqueue_outbound(target_chan, alerts_channel, text) or {
			eprintln('[alerts] channel enqueue failed: ${err}')
		}
		mut dms := 0
		if a.urgent {
			for sess in e.store.list_sessions() {
				if sess.pubkey_prefix.len == 0 || !e.wants_alert_dm(sess) {
					continue
				}
				e.store.enqueue_outbound(target_dm, sess.pubkey_prefix, text) or { continue }
				dms++
			}
		}
		println('[alerts] ${a.key}: channel${if dms > 0 { ' + ${dms} DM(s)' } else { '' }}')
		announced++
	}
	e.store.alert_keys_prune(now - alerts_forget_secs)
	return announced
}

// poll_alerts fetches and processes; failures are logged and retried next poll.
fn (mut e Engine) poll_alerts(now i64) {
	body := fetch_alerts_body() or {
		eprintln('[alerts] NWS fetch failed')
		return
	}
	e.process_alerts(body, now)
}
