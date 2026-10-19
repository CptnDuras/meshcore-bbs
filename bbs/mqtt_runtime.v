module main

import json2
import os
import sync
import time

// Daemon side of the optional MQTT observer. Owns the lifecycle of the in-process
// publisher (mqtt_publisher.v): starts it only while MQTT is enabled and fully
// configured, hot-reloads configuration when the web UI changes it, restarts it
// (with backoff) if it dies, and forwards heard packets to it.
//
// The radio loop must never block on MQTT, so packet delivery is a bounded,
// non-blocking queue: if the publisher stalls, packets are dropped and counted.

pub const mqtt_restart_backoff = 30 // seconds between publisher restarts
pub const mqtt_key_retry = 300 // seconds between private-key fetch attempts
pub const mqtt_log_keep_packets = 5000 // newest packet rows kept in the log
pub const mqtt_log_keep_other = 1000 // newest event rows kept (broker/daemon)
const mqtt_log_queue_max = 3000 // entries waiting for the next flush; extras are counted, not kept
const mqtt_log_trim_every = 60 // seconds between trims

// MqttPipe is the daemon's handle on a running publisher (faked in tests).
pub interface MqttPipe {
mut:
	alive() bool
	write_line(s string) bool // non-blocking; false = dropped
	read_status() ?string     // next status line the publisher reported, if any
	stop()
}

// MqttIdentity is what the radio told us about this node.
pub struct MqttIdentity {
pub mut:
	origin    string // node name
	origin_id string // 32-byte public key, hex
	model     string
	fw        string
}

pub struct MqttCfgBroker {
pub:
	id        int
	name      string
	host      string
	port      int
	transport string
	path      string
	auth      string
	audience  string
	username  string
	password  string
}

pub struct MqttCfgCmd {
pub:
	cmd       string
	iata      string
	origin    string
	origin_id string
	model     string
	fw        string
	key       string
	brokers   []MqttCfgBroker
}

pub struct MqttRuntime {
pub mut:
	factory      fn () !MqttPipe = unsafe { nil }
	ident        MqttIdentity
	key          string // 64-byte private key hex; memory only, never persisted
	key_loader   fn () !string = unsafe { nil } // fetches the key from the radio
	next_key_try i64
	dropped      int
	pipes        []MqttPipe // 0 or 1 element
	sent_rev     int = -1
	next_start   i64
	last_state   string
	mu           &sync.Mutex = sync.new_mutex()
	// activity log: entries are queued here (cheap, from any thread) and written
	// to the DB by tick(). It has its own lock so logging is safe wherever the
	// main lock is or is not held.
	lmu         &sync.Mutex = sync.new_mutex()
	log_q       []MqttLog
	log_over    int            // entries that did not fit the queue since the last flush
	log_dropped int            // r.dropped as of the last flush
	bstate      map[int]string // last logged state of each broker
	next_trim   i64
	now         i64 // time of the latest tick, used to stamp events
}

// log queues one activity-log entry. Never blocks on the database.
fn (mut r MqttRuntime) log(ts i64, kind string, broker string, summary string, detail string) {
	r.lmu.lock()
	defer {
		r.lmu.unlock()
	}
	if r.log_q.len >= mqtt_log_queue_max {
		r.log_over++
		return
	}
	r.log_q << MqttLog{
		ts:      ts
		kind:    kind
		broker:  broker
		summary: summary
		detail:  detail
	}
}

fn (mut r MqttRuntime) event(kind string, broker string, summary string) {
	r.log(r.now, kind, broker, summary, '')
}

// flush_log writes the queued entries to the DB and trims old rows.
fn (mut r MqttRuntime) flush_log(now i64, mut store Store) {
	r.lmu.lock()
	mut batch := r.log_q.clone()
	r.log_q.clear()
	over := r.log_over
	r.log_over = 0
	r.lmu.unlock()
	r.mu.lock()
	dropped := r.dropped
	r.mu.unlock()
	if dropped > r.log_dropped {
		batch << MqttLog{
			ts:      now
			kind:    'daemon'
			summary: '${dropped - r.log_dropped} packet(s) dropped: the publisher is not keeping up'
		}
		r.log_dropped = dropped
	}
	if over > 0 {
		batch << MqttLog{
			ts:      now
			kind:    'daemon'
			summary: '${over} log entries were not recorded (log queue was full)'
		}
	}
	if batch.len > 0 {
		store.add_mqtt_log(batch) or {}
	}
	if now >= r.next_trim {
		r.next_trim = now + mqtt_log_trim_every
		store.trim_mqtt_log(mqtt_log_keep_packets, mqtt_log_keep_other) or {}
	}
}

// log_status records a broker's state change (connecting -> connected, an error
// and its reason, ...). Repeats of the same state are not logged again.
fn (mut r MqttRuntime) log_status(line string, cfg MqttConfig) {
	m := json2.decode[MqttStatusMsg](line) or { return }
	if m.id <= 0 || m.t != 'status' {
		return
	}
	key := '${m.state}|${m.err_msg}'
	if r.bstate[m.id] == key {
		return
	}
	r.bstate[m.id] = key
	mut name := 'broker #${m.id}'
	for b in cfg.brokers {
		if b.id == m.id {
			name = b.name
			break
		}
	}
	r.event('broker', name, if m.err_msg.len > 0 { '${m.state}: ${m.err_msg}' } else { m.state })
}

fn mqtt_packet_type_name(t int) string {
	return match t {
		0 { 'REQ' }
		1 { 'RESPONSE' }
		2 { 'TXT_MSG' }
		3 { 'ACK' }
		4 { 'ADVERT' }
		5 { 'GRP_TXT' }
		6 { 'GRP_DATA' }
		7 { 'ANON_REQ' }
		8 { 'PATH' }
		9 { 'TRACE' }
		10 { 'MULTIPART' }
		11 { 'CONTROL' }
		15 { 'RAW_CUSTOM' }
		else { 'type ${t}' }
	}
}

// mqtt_needs_key is true when any enabled broker authenticates with a signed
// token, i.e. the publisher needs the node's private key.
pub fn mqtt_needs_key(cfg MqttConfig) bool {
	for b in cfg.brokers {
		if b.auth == 'token' {
			return true
		}
	}
	return false
}

fn mqtt_config_line(cfg MqttConfig, ident MqttIdentity, key string) string {
	mut brokers := []MqttCfgBroker{}
	for b in cfg.brokers {
		brokers << MqttCfgBroker{
			id:        b.id
			name:      b.name
			host:      b.host
			port:      b.port
			transport: b.transport
			path:      b.path
			auth:      b.auth
			audience:  b.audience
			username:  b.username
			password:  b.password
		}
	}
	return json2.encode(MqttCfgCmd{
		cmd:       'config'
		iata:      cfg.iata
		origin:    ident.origin
		origin_id: ident.origin_id
		model:     ident.model
		fw:        ident.fw
		key:       if mqtt_needs_key(cfg) { key } else { '' }
		brokers:   brokers
	},
		escape_unicode: true
	)
}

// MqttStatusMsg is one line the publisher prints on stdout.
struct MqttStatusMsg {
	t         string
	id        int
	state     string
	err_msg   string @[json: 'error']
	published i64
}

// apply_status applies one publisher status line to the store. Telemetry only:
// it never touches the configuration revision. Malformed lines are ignored.
fn apply_status(mut store Store, line string) {
	m := json2.decode[MqttStatusMsg](line) or { return }
	if m.id <= 0 {
		return
	}
	match m.t {
		'status' { store.set_mqtt_status(m.id, m.state, m.err_msg, m.published) or {} }
		'delete' { store.delete_mqtt_status(m.id) or {} }
		else {}
	}
}

fn (mut r MqttRuntime) note(mut store Store, state string) {
	if state == r.last_state {
		return
	}
	r.last_state = state
	store.mqtt_note('state', state) or {}
	r.event('daemon', '', state)
}

fn (mut r MqttRuntime) maybe_load_key(now i64, cfg MqttConfig, mut store Store) {
	if !cfg.enabled || !mqtt_needs_key(cfg) || r.key.len > 0 || r.key_loader == unsafe { nil }
		|| now < r.next_key_try {
		return
	}
	k := r.key_loader() or {
		r.next_key_try = now + mqtt_key_retry
		store.mqtt_note('key', 'error: ${err}') or {}
		r.log(now, 'daemon', '', 'private key not available: ${err}', '')
		return
	}
	if k.len != 128 {
		r.next_key_try = now + mqtt_key_retry
		store.mqtt_note('key', 'error: radio returned a malformed key') or {}
		r.log(now, 'daemon', '', 'radio returned a malformed private key', '')
		return
	}
	r.mu.lock()
	r.key = k
	r.sent_rev = -1 // re-send config so the publisher gets the key
	r.mu.unlock()
	store.mqtt_note('key', 'ok') or {}
	r.log(now, 'daemon', '', 'private key read from the radio (kept in memory only)', '')
}

fn (mut r MqttRuntime) shutdown() {
	if r.pipes.len > 0 {
		r.pipes[0].write_line('{"cmd":"stop"}')
		r.pipes[0].stop()
		r.pipes.clear()
	}
	r.sent_rev = -1
}

// tick reconciles the running publisher with the stored configuration.
// Call about once a second from the daemon loop.
pub fn (mut r MqttRuntime) tick(now i64, mut store Store) {
	r.now = now
	r.tick_inner(now, mut store)
	r.flush_log(now, mut store)
}

fn (mut r MqttRuntime) tick_inner(now i64, mut store Store) {
	cfg := load_mqtt_config(mut store)
	// Fetch the signing key BEFORE taking the lock: the radio's reply arrives
	// on the same dispatcher thread that calls on_packet(), so holding the lock
	// across the request would deadlock.
	r.maybe_load_key(now, cfg, mut store)
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	if !cfg.enabled {
		r.shutdown()
		r.note(mut store, 'off')
		return
	}
	if cfg.brokers.len == 0 {
		r.shutdown()
		r.note(mut store, 'waiting: no enabled broker configured')
		return
	}
	if !valid_iata(cfg.iata) {
		r.shutdown()
		r.note(mut store, 'waiting: set a 3-letter IATA code')
		return
	}
	if r.ident.origin_id.len != 64 {
		r.shutdown()
		r.note(mut store, 'waiting: radio identity not known yet')
		return
	}
	if r.pipes.len > 0 && !r.pipes[0].alive() {
		r.pipes.clear()
		r.next_start = now + mqtt_restart_backoff
		r.event('daemon', '', 'publisher exited')
	}
	if r.pipes.len == 0 {
		if now < r.next_start {
			r.note(mut store, 'restarting: publisher exited, retrying shortly')
			return
		}
		pipe := r.factory() or {
			r.next_start = now + mqtt_restart_backoff
			r.note(mut store, 'error: cannot start publisher: ${err}')
			return
		}
		r.pipes << pipe
		r.sent_rev = -1
		r.event('daemon', '', 'publisher started')
	}
	rev := store.mqtt_rev()
	if rev != r.sent_rev {
		if r.pipes[0].write_line(mqtt_config_line(cfg, r.ident, r.key)) {
			r.sent_rev = rev
			mut names := []string{}
			for b in cfg.brokers {
				names << b.name
			}
			r.event('daemon', '', 'configuration sent: IATA ${cfg.iata}, ${cfg.brokers.len} broker(s): ${names.join(', ')}')
		}
	}
	for _ in 0 .. 200 { // bounded: never let a chatty publisher stall the loop
		line := r.pipes[0].read_status() or { break }
		apply_status(mut store, line)
		r.log_status(line, cfg)
	}
	r.note(mut store, 'running: ${cfg.brokers.len} broker(s)')
}

// on_packet forwards one heard packet. Safe to call from the radio callback
// thread; never blocks.
pub fn (mut r MqttRuntime) on_packet(ts i64, snr f64, rssi f64, raw []u8) {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	if r.pipes.len == 0 {
		return
	}
	pj := observer_packet_json(r.ident.origin, r.ident.origin_id, ts, snr, rssi, raw) or { return }
	mut cmd := map[string]string{}
	cmd['cmd'] = 'packet'
	cmd['payload'] = pj
	queued := r.pipes[0].write_line(json2.encode(cmd, escape_unicode: true))
	if !queued {
		r.dropped++
	}
	if info := parse_packet(raw) {
		route := if info.route == 'D' { 'direct' } else { 'flood' }
		r.log(ts, 'packet', '', '${if queued { '' } else { 'NOT SENT (queue full) ' }}${mqtt_packet_type_name(info.packet_type)} ${route} ${info.raw_len} B  SNR ${int(snr)}  RSSI ${int(rssi)}  ${info.hash}',
			pj)
	}
}

// mqtt_home is the directory holding optional side files (such as cacert.pem):
// the MESHBBS_HOME env var, else the directory containing the meshbbs binary.
pub fn mqtt_home() string {
	return os.getenv_opt('MESHBBS_HOME') or { os.dir(os.executable()) }
}
