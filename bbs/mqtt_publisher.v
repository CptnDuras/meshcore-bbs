module main

import json2
import sync
import time

// In-process MQTT publisher: replaces the old Python process. The daemon talks
// to it through the same MqttPipe interface (JSON command lines in, JSON status
// lines out), so the runtime and web UI are unchanged.
//
//   MqttNativePipe   the MqttPipe: a command loop on its own thread
//   MqttPublisher    applies config/packet/stop commands, one worker per broker
//   MqttWorker       one thread per broker: dial, CONNECT, publish, keepalive,
//                    token refresh, reconnect with backoff

const mqtt_client_version = 'meshbbs-mqtt/1'
const mqtt_keepalive = 60 // seconds
const mqtt_token_ttl = 3600
const mqtt_token_refresh_after = 3000 // re-issue well before the 1h expiry
const mqtt_connack_wait_ms = 10000
const mqtt_max_backoff = 120
const mqtt_stop_wait_ms = 3000

// ---- identity, topics, credentials -------------------------------------------

pub struct MqttPubCore {
pub:
	iata      string
	origin    string
	origin_id string
	model     string
	fw        string
	key       string // 64-byte private key hex; empty when the radio has not given it
}

fn (c MqttPubCore) topic(kind string) string {
	return 'meshcore/${c.iata}/${c.origin_id.to_upper()}/${kind}'
}

struct MqttStatusPayload {
	status           string
	timestamp        string
	origin           string
	origin_id        string
	model            string
	firmware_version string
	client_version   string
}

fn (c MqttPubCore) status_json(status string, ts i64) string {
	t := time.unix(ts)
	return json2.encode(MqttStatusPayload{
		status:           status
		timestamp:        '${t.year:04}-${t.month:02}-${t.day:02}T${t.hour:02}:${t.minute:02}:${t.second:02}Z'
		origin:           c.origin
		origin_id:        c.origin_id
		model:            if c.model.len > 0 { c.model } else { 'unknown' }
		firmware_version: if c.fw.len > 0 { c.fw } else { 'unknown' }
		client_version:   mqtt_client_version
	},
		escape_unicode: true
	)
}

// mqtt_client_id is unique per node and broker entry (MQTT 3.1.1 allows 23 chars).
fn mqtt_client_id(core MqttPubCore, broker_id int) string {
	short := core.origin_id#[..8].to_lower()
	return 'meshbbs_${short}_${broker_id}'#[..23]
}

struct MqttCreds {
	has_login bool
	username  string
	password  string
}

fn (c MqttPubCore) credentials(b MqttCfgBroker, now i64) !MqttCreds {
	match b.auth {
		'token' {
			if c.key.len == 0 {
				return error('no private key available from the radio (token auth needs key export)')
			}
			tok := mqtt_create_token(c.origin_id, c.key, b.audience, mqtt_token_ttl, now, mqtt_client_version)!
			return MqttCreds{
				has_login: true
				username:  mqtt_username(c.origin_id)
				password:  tok
			}
		}
		'password' {
			return MqttCreds{
				has_login: true
				username:  b.username
				password:  b.password
			}
		}
		else {
			return MqttCreds{}
		}
	}
}

pub struct MqttBrokerSpec {
pub:
	broker MqttCfgBroker
	core   MqttPubCore
}

// ---- status sink ---------------------------------------------------------------

// MqttSink receives per-broker telemetry (applied to the database by the daemon).
pub interface MqttSink {
mut:
	set(id int, state string, err string, published i64, ts i64)
	delete(id int)
}

@[heap]
pub struct MqttChanSink {
	ch chan string
}

fn (mut s MqttChanSink) push(line string) {
	select {
		s.ch <- line {
		}
		else {
		} // advisory: drop if the daemon is not draining
	}
}

pub fn (mut s MqttChanSink) set(id int, state string, err string, published i64, ts i64) {
	s.push(json2.encode(MqttStatusMsg{
		t:         'status'
		id:        id
		state:     state
		err_msg:   err
		published: published
	},
		escape_unicode: true
	))
}

pub fn (mut s MqttChanSink) delete(id int) {
	s.push(json2.encode(MqttStatusMsg{
		t:  'delete'
		id: id
	},
		escape_unicode: true
	))
}

// ---- one broker connection -----------------------------------------------------

// MqttLink is the manager's handle on a broker worker (faked in tests).
pub interface MqttLink {
mut:
	offer(payload string) bool // queue a packet payload; false if not connected or full
	stop(report bool)          // finish asynchronously: offline status, DISCONNECT; report "stopped"
	is_done() bool
}

fn mqtt_try_recv(ch chan string) ?string {
	select {
		s := <-ch {
			return s
		}
		else {
			return none
		}
	}
	return none
}

@[heap]
pub struct MqttWorker {
	spec MqttBrokerSpec
	dial MqttDialer = unsafe { nil }
	now  fn () i64  = unsafe { nil }
	out  chan string
mut:
	sink        MqttSink
	mu          &sync.Mutex = sync.new_mutex()
	stop_req    bool
	report_stop bool
	done        bool
	connected   bool
	// owned by the worker thread alone:
	published  i64
	token_time i64
	carry      []u8
}

// mqtt_start_worker launches the thread for one broker.
pub fn mqtt_start_worker(spec MqttBrokerSpec, dial MqttDialer, sink MqttSink, now fn () i64) MqttLink {
	mut w := &MqttWorker{
		spec: spec
		dial: dial
		now:  now
		out:  chan string{cap: 256}
		sink: sink
	}
	spawn mqtt_worker_main(mut w)
	return w
}

fn mqtt_worker_main(mut w MqttWorker) {
	w.run()
}

pub fn (mut w MqttWorker) offer(payload string) bool {
	w.mu.lock()
	ok := w.connected && !w.stop_req
	w.mu.unlock()
	if !ok {
		return false
	}
	select {
		w.out <- payload {
			return true
		}
		else {
			return false
		}
	}
	return false
}

pub fn (mut w MqttWorker) stop(report bool) {
	w.mu.lock()
	w.stop_req = true
	w.report_stop = report
	w.mu.unlock()
}

pub fn (mut w MqttWorker) is_done() bool {
	w.mu.lock()
	defer {
		w.mu.unlock()
	}
	return w.done
}

fn (mut w MqttWorker) stopping() bool {
	w.mu.lock()
	defer {
		w.mu.unlock()
	}
	return w.stop_req
}

fn (mut w MqttWorker) set_connected(v bool) {
	w.mu.lock()
	w.connected = v
	w.mu.unlock()
}

fn (mut w MqttWorker) report(state string, err string) {
	w.sink.set(w.spec.broker.id, state, err, w.published, w.now())
}

// nap sleeps up to secs seconds; false if a stop was requested meanwhile.
fn (mut w MqttWorker) nap(secs int) bool {
	for _ in 0 .. secs * 10 {
		if w.stopping() {
			return false
		}
		time.sleep(100 * time.millisecond)
	}
	return !w.stopping()
}

fn (mut w MqttWorker) run() {
	mut backoff := 1
	for !w.stopping() {
		w.report('connecting', '')
		mut conn := w.open() or {
			if w.stopping() {
				break
			}
			w.report('error', err.msg())
			if !w.nap(backoff) {
				break
			}
			backoff = if backoff * 2 > mqtt_max_backoff { mqtt_max_backoff } else { backoff * 2 }
			continue
		}
		backoff = 1
		reason := w.serve(mut conn)
		w.set_connected(false)
		conn.close()
		if reason == '' {
			break
		}
		if reason == 'refresh' {
			continue // reconnect at once with a fresh token
		}
		w.report('connecting', reason)
		if !w.nap(backoff) {
			break
		}
	}
	w.mu.lock()
	report := w.report_stop
	w.mu.unlock()
	if report {
		w.report('stopped', '')
	}
	w.mu.lock()
	w.done = true
	w.mu.unlock()
}

// open dials, sends CONNECT (with the retained-offline will) and waits for CONNACK.
fn (mut w MqttWorker) open() !MqttConn {
	core := w.spec.core
	b := w.spec.broker
	w.token_time = w.now()
	creds := core.credentials(b, w.token_time)!
	mut conn := w.dial(b)!
	opts := MqttConnectOpts{
		client_id:    mqtt_client_id(core, b.id)
		has_login:    creds.has_login
		username:     creds.username
		password:     creds.password
		keepalive:    mqtt_keepalive
		will_topic:   core.topic('status')
		will_payload: core.status_json('offline', w.now())
		will_retain:  true
	}
	conn.write_all(mqtt_connect_packet(opts)) or {
		conn.close()
		return err
	}
	mut buf := []u8{}
	deadline := time.ticks() + mqtt_connack_wait_ms
	for {
		if w.stopping() {
			conn.close()
			return error('stopped')
		}
		if time.ticks() > deadline {
			conn.close()
			return error('timed out waiting for CONNACK')
		}
		conn.read_some(mut buf) or {
			conn.close()
			return err
		}
		p := mqtt_next_packet(mut buf) or {
			conn.close()
			return err
		}
		if p.ptype == 0 {
			time.sleep(2 * time.millisecond)
			continue
		}
		if p.ptype != mqtt_pt_connack || p.body.len < 2 {
			conn.close()
			return error('unexpected reply to CONNECT')
		}
		if p.body[1] != 0 {
			conn.close()
			return error('connect refused: ${mqtt_connack_text(int(p.body[1]))}')
		}
		w.carry = buf.clone()
		return conn
	}
	return error('unreachable')
}

// serve runs one established session. It returns '' after a requested stop,
// 'refresh' when the token is due for renewal, otherwise why the link was lost.
fn (mut w MqttWorker) serve(mut conn MqttConn) string {
	core := w.spec.core
	pkt_topic := core.topic('packets')
	conn.write_all(mqtt_publish_packet(core.topic('status'), core.status_json('online', w.now()), true)) or { return 'connection lost: ${err}' }
	for {
		_ := mqtt_try_recv(w.out) or { break } // drop anything queued before this session
	}
	w.set_connected(true)
	w.report('connected', '')
	mut buf := w.carry.clone()
	w.carry.clear()
	needs_refresh := w.spec.broker.auth == 'token'
	mut last_rx := time.ticks()
	mut last_tx := last_rx
	mut last_report := last_rx
	mut dirty := false
	for {
		if w.stopping() {
			conn.write_all(mqtt_publish_packet(core.topic('status'), core.status_json('offline', w.now()), true)) or {}
			conn.write_all(mqtt_disconnect) or {}
			return ''
		}
		mut busy := false
		for _ in 0 .. 64 {
			p := mqtt_try_recv(w.out) or { break }
			conn.write_all(mqtt_publish_packet(pkt_topic, p, false)) or {
				return 'connection lost: ${err}'
			}
			w.published++
			dirty = true
			busy = true
			last_tx = time.ticks()
		}
		conn.read_some(mut buf) or { return 'connection lost: ${err}' }
		for {
			p := mqtt_next_packet(mut buf) or { return 'protocol error: ${err}' }
			if p.ptype == 0 {
				break
			}
			last_rx = time.ticks()
			busy = true
		}
		t := time.ticks()
		if t - last_tx >= mqtt_keepalive * 500 {
			conn.write_all(mqtt_pingreq) or { return 'connection lost: ${err}' }
			last_tx = t
		}
		if t - last_rx > mqtt_keepalive * 1500 {
			return 'keepalive timeout'
		}
		if needs_refresh && w.now() - w.token_time >= mqtt_token_refresh_after {
			conn.write_all(mqtt_disconnect) or {}
			return 'refresh'
		}
		if dirty && t - last_report >= 1000 {
			w.report('connected', '')
			dirty = false
			last_report = t
		}
		if !busy {
			time.sleep(2 * time.millisecond)
		}
	}
	return 'unreachable'
}

// ---- manager -------------------------------------------------------------------

// MqttInCmd is one command line from the daemon.
pub struct MqttInCmd {
pub:
	cmd       string
	iata      string
	origin    string
	origin_id string
	model     string
	fw        string
	key       string
	brokers   []MqttCfgBroker
	payload   string
}

struct MqttConnEntry {
	fingerprint string
	has_link    bool
mut:
	link MqttLink
}

pub struct MqttPublisher {
mut:
	sink     MqttSink
	starter  fn (spec MqttBrokerSpec) MqttLink = unsafe { nil }
	now      fn () i64                         = unsafe { nil }
	has_core bool
	core     MqttPubCore
	conns    map[int]MqttConnEntry
}

pub fn new_mqtt_publisher(sink MqttSink, starter fn (spec MqttBrokerSpec) MqttLink, now fn () i64) &MqttPublisher {
	return &MqttPublisher{
		sink:    sink
		starter: starter
		now:     now
	}
}

pub fn (mut p MqttPublisher) handle(m MqttInCmd) {
	match m.cmd {
		'config' { p.apply_config(m) }
		'packet' { p.packet(m.payload) }
		'stop' { p.stop_all(true) }
		else {}
	}
}

fn (mut p MqttPublisher) wait_done(mut link MqttLink) {
	deadline := time.ticks() + mqtt_stop_wait_ms
	for !link.is_done() && time.ticks() < deadline {
		time.sleep(10 * time.millisecond)
	}
}

fn (mut p MqttPublisher) stop_entry(id int, report bool) {
	mut e := p.conns[id] or { return }
	if e.has_link {
		e.link.stop(report)
		p.wait_done(mut e.link)
	}
}

fn (mut p MqttPublisher) stop_all(report bool) {
	// ask every worker first so they finish in parallel, then wait for each
	for id in p.conns.keys() {
		mut e := p.conns[id] or { continue }
		if e.has_link {
			e.link.stop(report)
		}
	}
	for id in p.conns.keys() {
		mut e := p.conns[id] or { continue }
		if e.has_link {
			p.wait_done(mut e.link)
		}
	}
}

fn (mut p MqttPublisher) apply_config(m MqttInCmd) {
	core := MqttPubCore{
		iata:      m.iata.to_upper()
		origin:    m.origin
		origin_id: m.origin_id.to_upper()
		model:     m.model
		fw:        m.fw
		key:       m.key
	}
	if p.has_core && p.core != core {
		p.stop_all(false)
		p.conns.clear()
	}
	p.core = core
	p.has_core = true
	mut wanted := map[int]bool{}
	for b in m.brokers {
		wanted[b.id] = true
	}
	for id in p.conns.keys() {
		if id !in wanted {
			p.stop_entry(id, false)
			p.sink.delete(id)
			p.conns.delete(id)
		}
	}
	for b in m.brokers {
		fp := json2.encode(b)
		if cur := p.conns[b.id] {
			if cur.fingerprint == fp {
				continue
			}
			p.stop_entry(b.id, false) // wait: the replacement reuses the client id
		}
		p.start(b, fp)
	}
}

fn (mut p MqttPublisher) start(b MqttCfgBroker, fp string) {
	p.core.credentials(b, p.now()) or {
		// e.g. token auth without a key: report it and run nothing
		p.sink.set(b.id, 'error', err.msg(), 0, p.now())
		p.conns[b.id] = MqttConnEntry{
			fingerprint: fp
		}
		return
	}
	link := p.starter(MqttBrokerSpec{ broker: b, core: p.core })
	p.conns[b.id] = MqttConnEntry{
		fingerprint: fp
		has_link:    true
		link:        link
	}
}

fn (mut p MqttPublisher) packet(payload string) {
	if !p.has_core || payload.len == 0 {
		return
	}
	for id in p.conns.keys() {
		mut e := p.conns[id] or { continue }
		if e.has_link {
			e.link.offer(payload)
		}
	}
}

// ---- the MqttPipe the daemon holds ----------------------------------------------

@[heap]
pub struct MqttNativePipe {
	cmds   chan string
	status chan string
mut:
	mu        &sync.Mutex = sync.new_mutex()
	done      bool
	publisher &MqttPublisher = unsafe { nil }
}

// new_native_pipe starts the in-process publisher.
pub fn new_native_pipe() !MqttPipe {
	return new_native_pipe_with(mqtt_dial_real, mqtt_unix_now)
}

// new_native_pipe_with is new_native_pipe with the dialer and clock injected.
pub fn new_native_pipe_with(dial MqttDialer, now fn () i64) !MqttPipe {
	mut np := &MqttNativePipe{
		cmds:   chan string{cap: 512}
		status: chan string{cap: 256}
	}
	sink := &MqttChanSink{
		ch: np.status
	}
	np.publisher = new_mqtt_publisher(sink, fn [sink, dial, now] (spec MqttBrokerSpec) MqttLink {
		return mqtt_start_worker(spec, dial, sink, now)
	}, now)
	spawn mqtt_pipe_main(mut np)
	return np
}

fn mqtt_unix_now() i64 {
	return time.now().unix()
}

fn mqtt_pipe_main(mut np MqttNativePipe) {
	for {
		if line := mqtt_try_recv(np.cmds) {
			m := json2.decode[MqttInCmd](line) or { continue }
			np.publisher.handle(m)
			if m.cmd == 'stop' {
				break
			}
		} else {
			if np.cmds.closed {
				break
			}
			time.sleep(20 * time.millisecond)
		}
	}
	np.publisher.stop_all(true)
	np.mu.lock()
	np.done = true
	np.mu.unlock()
}

pub fn (mut np MqttNativePipe) alive() bool {
	np.mu.lock()
	defer {
		np.mu.unlock()
	}
	return !np.done
}

pub fn (mut np MqttNativePipe) write_line(s string) bool {
	select {
		np.cmds <- s {
			return true
		}
		else {
			return false
		}
	}
	return false
}

pub fn (mut np MqttNativePipe) read_status() ?string {
	return mqtt_try_recv(np.status)
}

// stop closes the command queue (a queued "stop" is still processed first) and
// waits for the brokers to be told goodbye.
pub fn (mut np MqttNativePipe) stop() {
	np.cmds.close()
	deadline := time.ticks() + 3 * mqtt_stop_wait_ms
	for np.alive() && time.ticks() < deadline {
		time.sleep(20 * time.millisecond)
	}
}
