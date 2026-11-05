module main

import mqttcfg
import os
import sync
import time

// The planner report: every few minutes this node posts what it has heard (see observe_agg.v) to a planner service, as one JSON document
// (schema 1), so the planner can draw the repeaters and rooms that were actually received next to the ones it estimates. Optional and
// off until it is configured on the MQTT page of the web UI.
//
//   POST <url>   X-Observer-Token: <token>   Content-Type: application/json
//   -> 200 {"batch": ..., "accepted": n, "ignored": n, "links": n, "duplicate": bool}
//
// The post runs on its own thread (a slow network must never hold up the BBS), and a report that could not be delivered is kept, unchanged and
// under the same batch id, and tried again: the service counts a batch id once, so a retry after a lost answer does not count twice.

const report_max_pending = 8
const report_backoff_start = 30
const report_backoff_max = 900

// ReportConfig is the effective configuration, read from the shared settings table.
pub struct ReportConfig {
pub mut:
	enabled         bool
	url             string
	token           string
	minutes         int
	public_position bool
	located         bool // the owner gave this node's position
	lat             f64
	lon             f64
	iata            string
}

// ready is true when a report can be sent: switched on, with an address and a token that pass the rules.
pub fn (c ReportConfig) ready() bool {
	return c.enabled && mqttcfg.valid_report_url(c.url) == '' && mqttcfg.valid_report_token(c.token)
}

// report_get is a plain function (not a closure): the ORM's `where key == key` must see an ordinary parameter.
fn report_get(mut store Store, key string) string {
	return store.mqtt_get(key) or { '' }
}

pub fn load_report_config(mut store Store) ReportConfig {
	lat, lon, located, _ := mqttcfg.parse_position(report_get(mut store, mqttcfg.report_key_lat), report_get(mut store, mqttcfg.report_key_lon))
	return ReportConfig{
		enabled:         report_get(mut store, mqttcfg.report_key_enabled) == '1'
		url:             report_get(mut store, mqttcfg.report_key_url).trim_space()
		token:           report_get(mut store, mqttcfg.report_key_token).trim_space()
		minutes:         mqttcfg.report_minutes(report_get(mut store, mqttcfg.report_key_minutes))
		public_position: report_get(mut store, mqttcfg.report_key_public) == '1'
		located:         located
		lat:             lat
		lon:             lon
		iata:            normalize_iata(report_get(mut store, 'iata'))
	}
}

// ObserverRadio is this node's radio setting, as the radio reported it at start-up.
pub struct ObserverRadio {
pub:
	freq f64
	bw   f64
	sf   int
	cr   int
	dbm  int
}

// --- the document ---

fn jq(s string) string {
	mut out := []u8{cap: s.len + 2}
	out << `"`
	for c in s.bytes() {
		match c {
			`"` { out << [u8(`\\`), `"`] }
			`\\` { out << [u8(`\\`), `\\`] }
			`\n` { out << [u8(`\\`), `n`] }
			`\r` { out << [u8(`\\`), `r`] }
			`\t` { out << [u8(`\\`), `t`] }
			else {
				if c < 0x20 {
					out << '\\u00${c:02x}'.bytes()
				} else {
					out << c
				}
			}
		}
	}
	out << `"`
	return out.bytestr()
}

fn jf(v f64, places int) string {
	return match places {
		6 { '${v:.6f}' }
		3 { '${v:.3f}' }
		else { '${v:.1f}' }
	}
}

fn node_json(n NodeAcc) string {
	mut snr := '{"min":0,"avg":0,"max":0}'
	mut rssi := '{"min":0,"avg":0,"max":0}'
	if n.direct_n > 0 { // only adverts that came straight from the node say anything about the link to it
		d := f64(n.direct_n)
		snr = '{"min":${jf(n.snr_min, 1)},"avg":${jf(n.snr_sum / d, 1)},"max":${jf(n.snr_max, 1)}}'
		rssi = '{"min":${jf(n.rssi_min, 0)},"avg":${jf(n.rssi_sum / d, 0)},"max":${jf(n.rssi_max, 0)}}'
	}
	return '{"pubkey":${jq(n.pubkey)},"name":${jq(n.name)},"role":${jq(n.role)},"lat":${jf(n.lat, 6)},"lon":${jf(n.lon, 6)},' +
		'"last_advert":${n.last_advert},"heard":${n.heard},"last_heard":${n.last_heard},"snr":${snr},"rssi":${rssi},"hops_min":${n.hops_min}}'
}

fn link_json(l LinkAcc) string {
	// the signal between two repeaters is not something this radio can measure, so it says none
	return '{"from":${jq(l.a)},"to":${jq(l.b)},"n":${l.n},"snr_avg":0,"last":${l.last}}'
}

// report_json builds the document for one window. Pure: the same inputs give the same text.
pub fn report_json(batch string, now i64, ident MqttIdentity, cfg ReportConfig, radio ObserverRadio, w Window) string {
	pos := if cfg.located { '"lat":${jf(cfg.lat, 6)},"lon":${jf(cfg.lon, 6)},' } else { '' }
	observer := '{"pubkey":${jq(ident.origin_id.to_lower())},"name":${jq(ident.origin)},"iata":${jq(cfg.iata)},${pos}' +
		'"public_position":${cfg.public_position && cfg.located},"radio":{"freq":${jf(radio.freq, 3)},"bw":${jf(radio.bw, 3)},"sf":${radio.sf},"cr":${radio.cr},"dbm":${radio.dbm}}}'
	nodes := w.nodes.map(node_json(it)).join(',')
	links := w.links.map(link_json(it)).join(',')
	return '{"schema":1,"batch":${jq(batch)},"sent":${now},"window":{"from":${w.from},"to":${w.to}},"observer":${observer},"nodes":[${nodes}],"links":[${links}]}'
}

// --- the post ---

pub struct PostReply {
pub:
	status int // HTTP status; 0 = no answer at all
	body   string
	err    string // why there was no answer
}

// Poster delivers one document. The real one runs curl (like the other fetchers here: V's own HTTPS crashes on this system); tests use a fake.
pub interface Poster {
mut:
	post(url string, token string, body string) PostReply
}

// Launcher runs a job off the main loop.
pub interface Launcher {
	launch(job fn ())
}

pub struct ThreadLauncher {}

pub fn (l ThreadLauncher) launch(job fn ()) {
	spawn job()
}

pub struct CurlPoster {
pub mut:
	n int
}

// curl_command is the command line for one post. The address was checked by mqttcfg.valid_report_url (nothing in it can end the quotes), the
// token is in a file so it never shows in the process list, and the body is a file so its size does not matter.
pub fn curl_command(url string, headers_file string, body_file string, out_file string) string {
	return "curl -s -m 30 -o '${out_file}' -w '%{http_code}' -X POST -H '@${headers_file}' --data-binary '@${body_file}' '${url}'"
}

fn private_file(path string, content string) ! {
	os.write_file(path, '')!
	os.chmod(path, 0o600)!
	os.write_file(path, content)!
}

pub fn (mut p CurlPoster) post(url string, token string, body string) PostReply {
	p.n++
	base := os.join_path(os.temp_dir(), 'meshbbs-report-${os.getpid()}-${p.n}')
	hdr, bod, out := base + '.h', base + '.b', base + '.o'
	defer {
		for f in [hdr, bod, out] {
			os.rm(f) or {}
		}
	}
	private_file(hdr, 'X-Observer-Token: ${token}\nContent-Type: application/json\n') or {
		return PostReply{
			err: 'cannot write a temporary file: ${err}'
		}
	}
	private_file(bod, body) or {
		return PostReply{
			err: 'cannot write a temporary file: ${err}'
		}
	}
	res := os.execute(curl_command(url, hdr, bod, out))
	if res.exit_code != 0 {
		return PostReply{
			err: 'curl failed (exit ${res.exit_code})'
		}
	}
	return PostReply{
		status: res.output.trim_space().int()
		body:   os.read_file(out) or { '' }
	}
}

// --- the reporter ---

struct Pending {
	batch string
	body  string
	nodes int
	links int
}

@[heap]
pub struct Reporter {
pub mut:
	agg      &Aggregator = unsafe { nil }
	poster   Poster
	launcher Launcher
	ident    MqttIdentity
	radio    ObserverRadio
mut:
	mu          &sync.Mutex = sync.new_mutex()
	cfg         ReportConfig
	rev         int = -1
	next_window i64
	next_try    i64
	fails       int
	counter     int
	pending     []Pending
	inflight    bool
	finished    bool // the thread's answer is waiting to be taken
	fin_ok      bool
	fin_drop    bool // the service said this report can never be accepted: do not send it again
	fin_text    string
	last_state  string
}

fn (mut r Reporter) note(mut store Store, state string) {
	if state == r.last_state {
		return
	}
	r.last_state = state
	store.mqtt_note('report_state', state) or {}
}

// tick is called about once a second from the daemon loop. It reloads the settings when the web UI changed them, closes a window when it is
// due, and starts delivering what is waiting.
pub fn (mut r Reporter) tick(now i64, mut store Store) {
	rev := store.mqtt_rev()
	if rev != r.rev {
		r.rev = rev
		r.cfg = load_report_config(mut store)
		r.agg.set_on(r.cfg.ready() && r.ident.origin_id.len == 64, now)
		r.next_window = now + i64(r.cfg.minutes) * 60
		if !r.cfg.ready() {
			r.pending.clear()
		}
	}
	if !r.cfg.enabled {
		r.note(mut store, 'off')
		return
	}
	if !r.cfg.ready() {
		r.note(mut store, 'waiting: set an https address and a token of at least ${mqttcfg.report_min_token} characters')
		return
	}
	if r.ident.origin_id.len != 64 {
		r.note(mut store, 'waiting: radio identity not known yet')
		return
	}
	if r.last_state == '' || r.last_state == 'off' || r.last_state.starts_with('waiting') {
		r.note(mut store, 'on: reporting every ${r.cfg.minutes} minutes; the first report goes out after the first window in which something was heard')
	}
	r.settle(now, mut store)
	if now >= r.next_window {
		r.next_window = now + i64(r.cfg.minutes) * 60
		w := r.agg.take(now)
		if w.nodes.len > 0 || w.links.len > 0 {
			r.counter++
			batch := '${r.ident.origin_id[..8].to_lower()}-${now}-${r.counter}'
			r.pending << Pending{
				batch: batch
				body:  report_json(batch, now, r.ident, r.cfg, r.radio, w)
				nodes: w.nodes.len
				links: w.links.len
			}
			if r.pending.len > report_max_pending {
				r.pending.delete(0) // the oldest goes: the service has been out of reach for a long time
			}
		}
	}
	r.send(now)
}

// settle takes the answer of the last post, if one has come back.
fn (mut r Reporter) settle(now i64, mut store Store) {
	r.mu.lock()
	done := r.finished
	ok := r.fin_ok
	drop := r.fin_drop
	text := r.fin_text
	if done {
		r.finished = false
		r.inflight = false
	}
	r.mu.unlock()
	if !done {
		return
	}
	if ok || drop {
		if r.pending.len > 0 {
			sent := r.pending[0]
			r.pending.delete(0)
			if ok {
				store.mqtt_note('report_last_ok', now.str()) or {}
				r.note(mut store, 'ok: sent ${sent.nodes} repeater(s) and ${sent.links} link(s) ${time.unix(now).format_ss()}')
			}
		}
		r.fails = 0
		r.next_try = 0
		if drop {
			r.note(mut store, 'error: the service refused a report and it was dropped (${text})')
		}
		return
	}
	r.fails++
	wait := report_backoff_start * (1 << (if r.fails > 5 { 5 } else { r.fails - 1 }))
	r.next_try = now + (if wait > report_backoff_max { report_backoff_max } else { wait })
	r.note(mut store, 'error: ${text}; trying again in ${r.next_try - now} s')
}

fn (mut r Reporter) send(now i64) {
	r.mu.lock()
	busy := r.inflight
	r.mu.unlock()
	if busy || r.pending.len == 0 || now < r.next_try {
		return
	}
	job := r.pending[0]
	cfg := r.cfg
	r.mu.lock()
	r.inflight = true
	r.mu.unlock()
	r.launcher.launch(fn [mut r, job, cfg] () {
		reply := r.poster.post(cfg.url, cfg.token, job.body)
		r.finish(reply)
	})
}

// finish runs on the posting thread: it only records the answer; tick() acts on it.
fn (mut r Reporter) finish(reply PostReply) {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	r.finished = true
	r.fin_ok = reply.status == 200
	r.fin_drop = reply.status == 400 || reply.status == 413
	r.fin_text = if reply.err != '' { reply.err } else { 'the service answered ${reply.status}' }
}
