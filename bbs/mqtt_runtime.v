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

// MqttPipe is the daemon's handle on a running publisher (faked in tests).
pub interface MqttPipe {
mut:
	alive() bool
	write_line(s string) bool // non-blocking; false = dropped
	read_status() ?string // next status line the publisher reported, if any
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
			id: b.id
			name: b.name
			host: b.host
			port: b.port
			transport: b.transport
			path: b.path
			auth: b.auth
			audience: b.audience
			username: b.username
			password: b.password
		}
	}
	return json2.encode(MqttCfgCmd{
		cmd: 'config'
		iata: cfg.iata
		origin: ident.origin
		origin_id: ident.origin_id
		model: ident.model
		fw: ident.fw
		key: if mqtt_needs_key(cfg) { key } else { '' }
		brokers: brokers
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
}

fn (mut r MqttRuntime) maybe_load_key(now i64, cfg MqttConfig, mut store Store) {
	if !cfg.enabled || !mqtt_needs_key(cfg) || r.key.len > 0 || r.key_loader == unsafe { nil }
		|| now < r.next_key_try {
		return
	}
	k := r.key_loader() or {
		r.next_key_try = now + mqtt_key_retry
		store.mqtt_note('key', 'error: ${err}') or {}
		return
	}
	if k.len != 128 {
		r.next_key_try = now + mqtt_key_retry
		store.mqtt_note('key', 'error: radio returned a malformed key') or {}
		return
	}
	r.mu.lock()
	r.key = k
	r.sent_rev = -1 // re-send config so the publisher gets the key
	r.mu.unlock()
	store.mqtt_note('key', 'ok') or {}
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
	}
	rev := store.mqtt_rev()
	if rev != r.sent_rev {
		if r.pipes[0].write_line(mqtt_config_line(cfg, r.ident, r.key)) {
			r.sent_rev = rev
		}
	}
	for _ in 0 .. 200 { // bounded: never let a chatty publisher stall the loop
		line := r.pipes[0].read_status() or { break }
		apply_status(mut store, line)
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
	if !r.pipes[0].write_line(json2.encode(cmd, escape_unicode: true)) {
		r.dropped++
	}
}

// mqtt_home is the directory holding optional side files (such as cacert.pem):
// the MESHBBS_HOME env var, else the directory containing the meshbbs binary.
pub fn mqtt_home() string {
	return os.getenv_opt('MESHBBS_HOME') or { os.dir(os.executable()) }
}
